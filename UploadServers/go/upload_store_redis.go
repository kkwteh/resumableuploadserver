package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
	"github.com/redis/go-redis/v9"
)

// RedisStore persists upload state in Redis with a local cache for active uploads.
type RedisStore struct {
	client *redis.Client
	ttl    time.Duration
	mu     sync.Mutex
	cache  map[string]*upload
}

func NewRedisStore(redisURL string, ttl time.Duration) (*RedisStore, error) {
	opts, err := redis.ParseURL(redisURL)
	if err != nil {
		return nil, fmt.Errorf("parse redis URL: %w", err)
	}

	client := redis.NewClient(opts)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping: %w", err)
	}

	return &RedisStore{
		client: client,
		ttl:    ttl,
		cache:  make(map[string]*upload),
	}, nil
}

func redisKey(token string) string {
	return "upload:" + token
}

type partRecord struct {
	ETag       string `json:"etag"`
	PartNumber int32  `json:"part_number"`
}

func marshalUpload(u *upload) map[string]interface{} {
	fields := map[string]interface{}{
		"complete":       boolToStr(u.complete),
		"start_time":     u.startTime.Unix(),
		"flushed_offset": computeFlushedOffset(u),
	}

	switch st := u.backendState.(type) {
	case *s3State:
		fields["backend"] = "s3"
		fields["key"] = st.key
		fields["upload_id"] = st.uploadID
		fields["next_part_num"] = st.nextPartNum

		parts := make([]partRecord, len(st.completedParts))
		for i, p := range st.completedParts {
			parts[i] = partRecord{
				ETag:       aws.ToString(p.ETag),
				PartNumber: aws.ToInt32(p.PartNumber),
			}
		}
		partsJSON, _ := json.Marshal(parts)
		fields["completed_parts"] = string(partsJSON)

	case *localState:
		fields["backend"] = "local"
		fields["file_path"] = st.filePath
	}

	return fields
}

func unmarshalUpload(token string, vals map[string]string) (*upload, error) {
	u := &upload{
		token: token,
	}

	if v, ok := vals["complete"]; ok {
		u.complete = v == "1"
	}
	if v, ok := vals["start_time"]; ok {
		ts, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("parse start_time: %w", err)
		}
		u.startTime = time.Unix(ts, 0)
	}

	flushedOffset := int64(0)
	if v, ok := vals["flushed_offset"]; ok {
		fo, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			return nil, fmt.Errorf("parse flushed_offset: %w", err)
		}
		flushedOffset = fo
	}

	backend := vals["backend"]
	switch backend {
	case "s3":
		st := &s3State{
			key:      vals["key"],
			uploadID: vals["upload_id"],
		}
		if v, ok := vals["next_part_num"]; ok {
			n, err := strconv.ParseInt(v, 10, 32)
			if err != nil {
				return nil, fmt.Errorf("parse next_part_num: %w", err)
			}
			st.nextPartNum = int32(n)
		}
		if v, ok := vals["completed_parts"]; ok && v != "" {
			var parts []partRecord
			if err := json.Unmarshal([]byte(v), &parts); err != nil {
				return nil, fmt.Errorf("parse completed_parts: %w", err)
			}
			st.completedParts = make([]types.CompletedPart, len(parts))
			for i, p := range parts {
				st.completedParts[i] = types.CompletedPart{
					ETag:       aws.String(p.ETag),
					PartNumber: aws.Int32(p.PartNumber),
				}
			}
		}
		// pendingBuf is empty on recovery — client re-sends from flushedOffset
		u.backendState = st

	case "local":
		u.backendState = &localState{filePath: vals["file_path"]}

	default:
		return nil, fmt.Errorf("unknown backend: %q", backend)
	}

	// On recovery, offset = flushedOffset (pending bytes are lost)
	u.offset = flushedOffset

	return u, nil
}

func computeFlushedOffset(u *upload) int64 {
	if st, ok := u.backendState.(*s3State); ok {
		return u.offset - int64(len(st.pendingBuf))
	}
	return u.offset
}

func boolToStr(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

func (r *RedisStore) Create(ctx context.Context, u *upload) error {
	key := redisKey(u.token)
	fields := marshalUpload(u)

	pipe := r.client.Pipeline()
	pipe.HSet(ctx, key, fields)
	pipe.Expire(ctx, key, r.ttl)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("redis create: %w", err)
	}

	r.mu.Lock()
	r.cache[u.token] = u
	r.mu.Unlock()

	return nil
}

func (r *RedisStore) Find(ctx context.Context, token string) (*upload, error) {
	// Check local cache first
	r.mu.Lock()
	if u, ok := r.cache[token]; ok {
		r.mu.Unlock()
		return u, nil
	}
	r.mu.Unlock()

	// Cache miss — fetch from Redis
	vals, err := r.client.HGetAll(ctx, redisKey(token)).Result()
	if err != nil {
		return nil, fmt.Errorf("redis hgetall: %w", err)
	}
	if len(vals) == 0 {
		return nil, nil
	}

	u, err := unmarshalUpload(token, vals)
	if err != nil {
		return nil, err
	}

	// Cache for subsequent calls
	r.mu.Lock()
	r.cache[token] = u
	r.mu.Unlock()

	return u, nil
}

func (r *RedisStore) Save(ctx context.Context, u *upload) error {
	key := redisKey(u.token)
	fields := marshalUpload(u)

	pipe := r.client.Pipeline()
	pipe.HSet(ctx, key, fields)
	pipe.Expire(ctx, key, r.ttl)
	if _, err := pipe.Exec(ctx); err != nil {
		return fmt.Errorf("redis save: %w", err)
	}

	return nil
}

func (r *RedisStore) Delete(ctx context.Context, token string) error {
	if err := r.client.Del(ctx, redisKey(token)).Err(); err != nil {
		return fmt.Errorf("redis del: %w", err)
	}

	r.mu.Lock()
	delete(r.cache, token)
	r.mu.Unlock()

	return nil
}
