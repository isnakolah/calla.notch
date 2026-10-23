package index

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Embedder turns text into vectors of a fixed dimension (384 in the schema).
type Embedder interface {
	Embed(ctx context.Context, texts []string) ([][]float32, error)
	EmbedQuery(ctx context.Context, q string) ([]float32, error)
}

// TEI talks to a Hugging Face text-embeddings-inference server running
// BAAI/bge-small-en-v1.5 on loopback.
type TEI struct {
	URL    string
	Client *http.Client
}

func NewTEI(url string) *TEI {
	return &TEI{URL: url, Client: &http.Client{Timeout: 60 * time.Second}}
}

// bge models expect this instruction on queries, not on passages.
const bgeQueryPrefix = "Represent this sentence for searching relevant passages: "

func (t *TEI) Embed(ctx context.Context, texts []string) ([][]float32, error) {
	var out [][]float32
	for start := 0; start < len(texts); start += 32 {
		end := min(start+32, len(texts))
		batch, err := t.embed(ctx, texts[start:end])
		if err != nil {
			return nil, err
		}
		out = append(out, batch...)
	}
	return out, nil
}

func (t *TEI) EmbedQuery(ctx context.Context, q string) ([]float32, error) {
	v, err := t.embed(ctx, []string{bgeQueryPrefix + q})
	if err != nil {
		return nil, err
	}
	return v[0], nil
}

func (t *TEI) embed(ctx context.Context, texts []string) ([][]float32, error) {
	body, _ := json.Marshal(map[string]any{"inputs": texts, "truncate": true, "normalize": true})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.URL+"/embed", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := t.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return nil, fmt.Errorf("embed: %s: %s", resp.Status, msg)
	}
	var vecs [][]float32
	if err := json.NewDecoder(resp.Body).Decode(&vecs); err != nil {
		return nil, err
	}
	if len(vecs) != len(texts) {
		return nil, fmt.Errorf("embed: got %d vectors for %d inputs", len(vecs), len(texts))
	}
	return vecs, nil
}
