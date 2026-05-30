package main

import (
	"errors"
	"fmt"
	"os"
)

func main() {
	for _, path := range []string{"agent_gen.go", "client_gen.go", "helpers_gen.go"} {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			fmt.Fprintf(os.Stderr, "remove %s: %v\n", path, err)
			os.Exit(1)
		}
	}
}
