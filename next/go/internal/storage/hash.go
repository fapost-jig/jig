package storage

import (
	"crypto/sha1" //nolint:gosec // the object name git gives a blob, not a security measure
	"encoding/hex"
	"fmt"
	"os"
)

// BlobSHA1 is the object name `git hash-object --no-filters` gives data in a
// repository of the sha1 object format: the hash of `blob <len>\0` and the bytes.
func BlobSHA1(data []byte) string {
	h := sha1.New() //nolint:gosec
	fmt.Fprintf(h, "blob %d\x00", len(data))
	h.Write(data)
	return hex.EncodeToString(h.Sum(nil))
}

// HashFileSHA1 is BlobSHA1 of the file at path, links followed as git follows
// them for a path it is handed on stdin.
func HashFileSHA1(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if info.IsDir() {
		return "", fmt.Errorf("%s: is a directory", path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return BlobSHA1(data), nil
}
