package providertest

import (
	"encoding/json"
	"flag"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

var update = flag.Bool("update", false, "record golden files as the code writes them now")

// Golden fails when got differs from the file at path, with what changed and
// why that matters. Run the test with -update to record got.
func Golden(t *testing.T, path, got, why string) {
	t.Helper()
	if *update {
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v\n\nRecord it: go test -run '^%s$' -update", err, t.Name())
	}
	if got == string(want) {
		return
	}
	var changed strings.Builder
	recorded, current := lineSet(string(want)), lineSet(got)
	for _, line := range strings.Split(string(want), "\n") {
		if !current[line] {
			changed.WriteString("- " + line + "\n")
		}
	}
	for _, line := range strings.Split(got, "\n") {
		if !recorded[line] {
			changed.WriteString("+ " + line + "\n")
		}
	}
	t.Fatalf("%s no longer matches what the code writes:\n\n%s\n%s\n\nThen record it: go test -run '^%s$' -update", path, changed.String(), why, t.Name())
}

func lineSet(text string) map[string]bool {
	lines := make(map[string]bool)
	for _, line := range strings.Split(text, "\n") {
		lines[line] = true
	}
	return lines
}

// SampleJSON is the JSON of a value of zero's type with every field set,
// however deep: the whole of the type's encoding, so a renamed, added or
// removed field shows.
func SampleJSON(t *testing.T, zero any) string {
	t.Helper()
	value := reflect.New(reflect.TypeOf(zero)).Elem()
	fill(value, map[reflect.Type]bool{})
	raw, err := json.MarshalIndent(value.Interface(), "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

var (
	timeType = reflect.TypeFor[time.Time]()
	rawType  = reflect.TypeFor[json.RawMessage]()
)

// fill sets every field of value. inside holds the struct types being
// filled around it: a type that contains itself is filled once and left
// zero where it comes up again.
func fill(value reflect.Value, inside map[reflect.Type]bool) {
	switch {
	case value.Type() == timeType:
		value.Set(reflect.ValueOf(time.Date(2026, 1, 2, 3, 4, 5, 6, time.UTC)))
		return
	case value.Type() == rawType:
		value.Set(reflect.ValueOf(json.RawMessage(`{"any":"json"}`)))
		return
	}
	switch value.Kind() {
	case reflect.String:
		value.SetString("text")
	case reflect.Bool:
		value.SetBool(true)
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		value.SetInt(1)
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		value.SetUint(1)
	case reflect.Float32, reflect.Float64:
		value.SetFloat(1.5)
	case reflect.Pointer:
		value.Set(reflect.New(value.Type().Elem()))
		fill(value.Elem(), inside)
	case reflect.Slice:
		value.Set(reflect.MakeSlice(value.Type(), 1, 1))
		fill(value.Index(0), inside)
	case reflect.Map:
		key, element := reflect.New(value.Type().Key()).Elem(), reflect.New(value.Type().Elem()).Elem()
		fill(key, inside)
		fill(element, inside)
		value.Set(reflect.MakeMap(value.Type()))
		value.SetMapIndex(key, element)
	case reflect.Struct:
		if inside[value.Type()] {
			return
		}
		inside[value.Type()] = true
		defer delete(inside, value.Type())
		for index := range value.NumField() {
			if field := value.Field(index); field.CanSet() {
				fill(field, inside)
			}
		}
	case reflect.Interface:
		if text := reflect.ValueOf("any"); text.Type().AssignableTo(value.Type()) {
			value.Set(text)
		}
	}
}

// StringTypes are the named string types a value of zero's type can hold,
// however deep, by name: its closed vocabularies and its IDs.
func StringTypes(zero any) []string {
	seen := make(map[reflect.Type]bool)
	var names []string
	var walk func(reflect.Type)
	walk = func(kind reflect.Type) {
		if seen[kind] {
			return
		}
		seen[kind] = true
		switch kind.Kind() {
		case reflect.String:
			if kind.PkgPath() != "" {
				names = append(names, kind.Name())
			}
		case reflect.Pointer, reflect.Slice:
			walk(kind.Elem())
		case reflect.Map:
			walk(kind.Key())
			walk(kind.Elem())
		case reflect.Struct:
			for index := range kind.NumField() {
				if field := kind.Field(index); field.IsExported() {
					walk(field.Type)
				}
			}
		}
	}
	walk(reflect.TypeOf(zero))
	return names
}
