package main

import (
	"log"
	"os"

	"github.com/Aqothy/maiD/internal/cli"
)

func main() {
	if err := cli.RunAuto(os.Args); err != nil {
		log.Fatal(err)
	}
}
