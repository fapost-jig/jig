package core

import "fmt"

// Chunk is one piece of what a command printed, in the order it was printed.
type Chunk struct {
	Stderr bool
	Text   string
}

// Output is what a command printed, stdout and stderr interleaved as bash
// wrote them (a recording may merge the two streams), and its exit status.
// core never prints: cli writes the chunks.
type Output struct {
	Chunks []Chunk
	Code   int
}

func (o *Output) stdout(text string) {
	if text != "" {
		o.Chunks = append(o.Chunks, Chunk{Text: text})
	}
}

func (o *Output) stderr(text string) {
	if text != "" {
		o.Chunks = append(o.Chunks, Chunk{Stderr: true, Text: text})
	}
}

// Die prints what went wrong as jig_die does and sets the exit status 1.
func (o *Output) Die(err error) {
	o.stderr(fmt.Sprintf("jig: error: %s\n", err.Error()))
	o.Code = 1
}
