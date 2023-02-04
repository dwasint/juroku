package main

import (
	"flag"
	"image"
	_ "image/jpeg"
	"image/png"
	"log"
	"os"
	"time"

	_ "golang.org/x/image/bmp"

	"github.com/1lann/imagequant"
	"github.com/tmpim/juroku"
)

var (
	outputPath  = flag.String("o", "image.juf", "set location of output script")
	reference   = flag.String("r", "input_image", "set reference image to derive palette from")
	previewPath = flag.String("p", "preview.png", "set location of output preview (will be PNG)")
	speed       = flag.Int("q", 1, "set the processing speed/quality (1 = slowest, 10 = fastest)")
	dither      = flag.Float64("d", 0.2, "set the amount of allowed dithering (0 = none, 1 = most)")
	license     = flag.Bool("license", false, "show licensing disclaimers and exit")
)

func main() {
	flag.Parse()
	log.SetFlags(0)

	if *license {
		log.Println("Juroku itself is licensed under the MIT license, which can be found here:")
		log.Println("https://github.com/tmpim/juroku/blob/master/LICENSE")
		log.Println("However other portions of Juroku are under different licenses,")
		log.Println("the information of which can be found below.")
		log.Println(imagequant.License())
		os.Exit(0)
	}

	if *speed < 1 {
		log.Println("Speed cannot be less than 1.")
		os.Exit(1)
	}

	if *speed > 10 {
		log.Println("Speed cannot be greater than 10.")
		os.Exit(1)
	}

	if *dither < 0.0 {
		log.Println("Dither cannot be less than 0.")
		os.Exit(1)
	}

	if *dither > 1.0 {
		log.Println("Dither cannot be greater than 1.")
		os.Exit(1)
	}

	if flag.Arg(0) == "" {
		log.Println("Usage: juroku [options] input_image")
		log.Println("")
		log.Println("Juroku converts an image (PNG or JPG) into a Lua script that can be")
		log.Println("loaded as a ComputerCraft API to be used to draw on terminals and monitors.")
		log.Println("Images are not automatically downscaled or cropped.")
		log.Println("")
		log.Println("input_image must have a height that is a multiple of 3 in pixels,")
		log.Println("and a width that is a multiple of 2 in pixels.")
		log.Println("")
		log.Println("Options:")
		flag.PrintDefaults()
		log.Println("")
		log.Println("Disclaimer:")
		log.Println("  Juroku contains code licensed under GPLv3 which is subject to certain restrictions.")
		log.Println("  For full details and to view the full license, run `juroku -license`.")
		os.Exit(1)
	}

	start := time.Now()

	var img image.Image

	func() {
		input, err := os.Open(flag.Arg(0))
		if err != nil {
			log.Println("Failed to open image:", err)
			os.Exit(1)
		}
		defer input.Close()

		img, _, err = image.Decode(input)
		if err != nil {
			log.Println("Failed to decode image:", err)
			os.Exit(1)
		}

		if img.Bounds().Dy()%3 != 0 {
			log.Println("Image height must be a multiple of 3.")
			os.Exit(1)
		}

		if img.Bounds().Dx()%2 != 0 {
			log.Println("Image width must be a multiple of 2.")
			os.Exit(1)
		}
	}()

	var refImage image.Image
	if *reference == "input_image" {
		refImage = img
	} else {
		func() {
			input, err := os.Open(*reference)
			if err != nil {
				log.Println("Failed to open reference image:", err)
				os.Exit(1)
			}
			defer input.Close()

			refImage, _, err = image.Decode(input)
			if err != nil {
				log.Println("Failed to decode reference image:", err)
				os.Exit(1)
			}
		}()
	}

	log.Println("Image loaded, quantizing...")

	quant, err := juroku.Quantize(refImage, img, *speed, *dither)
	if err != nil {
		log.Println("Failed to quantize image:", err)
		os.Exit(1)
	}

	log.Println("Image quantized, chunking and generating code...")

	chunked, err := juroku.ChunkImage(quant)
	if err != nil {
		log.Println("Failed to chunk image:", err)
		os.Exit(1)
	}

	frame, err := juroku.GenerateFrameChunk(chunked)
	if err != nil {
		log.Println("Failed to generate code:", err)
		os.Exit(1)
	}

	func() {
		preview, err := os.Create(*previewPath)
		if err != nil {
			log.Println("Warning: Failed to create preview image:", err)
			return
		}

		defer preview.Close()

		err = png.Encode(preview, chunked)
		if err != nil {
			log.Println("Warning: Failed to encode preview image:", err)
		}
	}()

	output, err := os.Create(*outputPath)
	if err != nil {
		log.Println("Failed to create output file:", err)
		return
	}

	defer output.Close()

	err = frame.WriteTo(output)
	if err != nil {
		log.Println("Failed to write to output file:", err)
		return
	}

	log.Println("\nDone! That took " + time.Since(start).String() + ".")
	log.Printf("Code outputted to \"%s\", preview outputted to \"%s\".\n",
		*outputPath, *previewPath)
}
