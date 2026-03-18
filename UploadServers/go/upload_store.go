package main

import (
	"context"
	"fmt"
	"sync"
	"time"
)

// UploadStore abstracts upload state persistence.
type UploadStore interface {
	Create(ctx context.Context, u *upload) error
	Find(ctx context.Context, token string) (*upload, error) // nil, nil if not found
	Save(ctx context.Context, u *upload) error
	Delete(ctx context.Context, token string) error
}

// MemoryStore keeps upload state in-process with idle timeout cleanup.
type MemoryStore struct {
	mu      sync.Mutex
	uploads map[string]*upload
	storage Storage
}

func NewMemoryStore(storage Storage) *MemoryStore {
	return &MemoryStore{
		uploads: make(map[string]*upload),
		storage: storage,
	}
}

func (m *MemoryStore) Create(_ context.Context, u *upload) error {
	m.mu.Lock()
	m.uploads[u.token] = u
	m.mu.Unlock()

	u.timer = time.AfterFunc(idleTimeout, func() {
		fmt.Printf("[Upload] Timeout: removing upload %s after idle\n", u.token)
		m.storage.Abort(context.Background(), u)
		m.mu.Lock()
		delete(m.uploads, u.token)
		m.mu.Unlock()
	})

	return nil
}

func (m *MemoryStore) Find(_ context.Context, token string) (*upload, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.uploads[token], nil
}

func (m *MemoryStore) Save(_ context.Context, _ *upload) error {
	// No-op: state is already in memory.
	return nil
}

func (m *MemoryStore) Delete(_ context.Context, token string) error {
	m.mu.Lock()
	u := m.uploads[token]
	if u != nil {
		if u.timer != nil {
			u.timer.Stop()
		}
		delete(m.uploads, token)
	}
	m.mu.Unlock()
	return nil
}
