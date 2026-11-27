// Package archtest holds the architecture rules of this module, as tests: which
// package may import what, who may touch the file system, which dependencies
// may be there and under which licences, and that nothing needs cgo. They read
// the module's own source with go/parser and ask the go tool about the module
// graph; nothing needs the network beyond a populated module cache.
package archtest
