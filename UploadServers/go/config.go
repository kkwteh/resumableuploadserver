package main

import (
	"fmt"
	"os"
	"strconv"
)

const (
	defaultPartSize = 8 * 1024 * 1024 // 8MB
	minPartSize     = 5 * 1024 * 1024 // 5MB (S3 minimum)
)

type Config struct {
	Port        string
	Origin      string
	S3Bucket    string
	S3KeyPrefix string
	S3Endpoint  string
	S3PartSize  int
	AWSRegion   string
	RedisURL    string
}

func (c Config) UseS3() bool {
	return c.S3Bucket != ""
}

func (c Config) UseRedis() bool {
	return c.RedisURL != ""
}

func LoadConfig() Config {
	port := "8080"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	origin := fmt.Sprintf("http://localhost:%s", port)
	if len(os.Args) > 2 {
		origin = os.Args[2]
	}

	partSize := defaultPartSize
	if v := os.Getenv("S3_PART_SIZE"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			if n < minPartSize {
				fmt.Printf("Warning: S3_PART_SIZE %d is below minimum %d, using minimum\n", n, minPartSize)
				n = minPartSize
			}
			partSize = n
		}
	}

	region := os.Getenv("AWS_REGION")
	if region == "" {
		region = "us-east-1"
	}

	return Config{
		Port:        port,
		Origin:      origin,
		S3Bucket:    os.Getenv("S3_BUCKET"),
		S3KeyPrefix: os.Getenv("S3_KEY_PREFIX"),
		S3Endpoint:  os.Getenv("S3_ENDPOINT"),
		S3PartSize:  partSize,
		AWSRegion:   region,
		RedisURL:    os.Getenv("REDIS_URL"),
	}
}
