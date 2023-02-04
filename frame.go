package juroku

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"image/color"
	"io"
)

// FrameRow represents a row in a frame chunk.
type FrameRow struct {
	TextColor       *bytes.Buffer
	BackgroundColor *bytes.Buffer
	Text            *bytes.Buffer
}

// WriteTo writes the frame row to a writer.
func (f *FrameRow) WriteTo(wr io.Writer) (int, error) {
	total := 0
	n, err := wr.Write(f.TextColor.Bytes())
	total += n
	if err != nil {
		return total, err
	}

	n, err = wr.Write(f.BackgroundColor.Bytes())
	total += n
	if err != nil {
		return total, err
	}

	n, err = wr.Write(f.Text.Bytes())
	total += n
	if err != nil {
		return total, err
	}

	return total, nil
}

// FrameChunk represents a frame chunk.
type FrameChunk struct {
	Width  int
	Height int

	Rows []FrameRow

	Palette [16]color.RGBA
}

// WriteTo writes the frame chunk to a writer.
func (f *FrameChunk) WriteTo(w io.Writer) error {
	wr := bufio.NewWriter(w)

	binary.Write(wr, binary.BigEndian, uint16(f.Width))
	binary.Write(wr, binary.BigEndian, uint16(f.Height))

	for _, row := range f.Rows {
		row.WriteTo(wr)
	}

	for _, color := range f.Palette {
		wr.Write([]byte{color.R, color.G, color.B})
	}

	return wr.Flush()
}
