package wire

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
)

// goVocabularyTypes points each vocabulary at the Go type whose constants
// define it; coverage is then derived from the source.
var goVocabularyTypes = map[string]struct{ pkgDir, typeName string }{
	"EventType":              {"../../internal/orchestration", "EventType"},
	"CommandType":            {"../../internal/orchestration", "CommandType"},
	"StreamItemKind":         {"../../internal/orchestration", "StreamItemKind"},
	"ActorKind":              {"../../internal/orchestration", "ActorKind"},
	"TimelineEntryKind":      {"../../internal/orchestration", "TimelineEntryKind"},
	"MessageRole":            {"../../internal/orchestration", "MessageRole"},
	"TurnState":              {"../../internal/orchestration", "TurnState"},
	"SessionStatus":          {"../../internal/orchestration", "SessionStatus"},
	"ApprovalStatus":         {"../../internal/orchestration", "ApprovalStatus"},
	"ApprovalDecision":       {"../../internal/provider", "ApprovalDecision"},
	"RequestType":            {"../../internal/provider", "RuntimeRequestType"},
	"ItemKind":               {"../../internal/provider", "ItemKind"},
	"ItemStatus":             {"../../internal/provider", "ItemStatus"},
	"ToolAction":             {"../../internal/provider", "ToolAction"},
	"FileChangeKind":         {"../../internal/provider", "FileChangeKind"},
	"ConfigOptionType":       {"../../internal/provider", "ConfigOptionType"},
	"ConfigOptionCategory":   {"../../internal/provider", "ConfigOptionCategory"},
	"PlanEntryStatus":        {"../../internal/provider", "PlanEntryStatus"},
	"PlanEntryPriority":      {"../../internal/provider", "PlanEntryPriority"},
	"InstanceStatus":         {"../../internal/provider", "InstanceStatus"},
	"AuthStatus":             {"../../internal/provider", "AuthStatus"},
	"ModelSwitchSupport":     {"../../internal/provider", "ModelSwitchSupport"},
	"TerminalStatus":         {"../../internal/terminal", "Status"},
	"TerminalStreamItemKind": {"../../internal/terminal", "StreamItemKind"},
}

// Adding a constant without registering it would ship a value no generated
// client can name.
func TestVocabulariesCoverTheirGoConstants(t *testing.T) {
	for _, vocabulary := range Vocabularies {
		source, ok := goVocabularyTypes[vocabulary.Name]
		if !ok {
			t.Errorf("vocabulary %q has no Go constant source; add one to goVocabularyTypes", vocabulary.Name)
			continue
		}
		declared := stringConstantsOfType(t, source.pkgDir, source.typeName)
		if len(declared) == 0 {
			t.Errorf("vocabulary %q: no constants of type %s found in %s", vocabulary.Name, source.typeName, source.pkgDir)
			continue
		}
		for _, value := range declared {
			if !slices.Contains(vocabulary.Values, value) {
				t.Errorf("vocabulary %q is missing %s constant %q; add it to wire.Vocabularies so clients can name it", vocabulary.Name, source.typeName, value)
			}
		}
		for _, value := range vocabulary.Values {
			if !slices.Contains(declared, value) {
				t.Errorf("vocabulary %q lists %q, which is not a %s constant", vocabulary.Name, value, source.typeName)
			}
		}
	}
}

func TestVocabularyNamesAndValuesAreUnique(t *testing.T) {
	seenNames := make(map[string]struct{}, len(Vocabularies))
	for _, vocabulary := range Vocabularies {
		if _, duplicate := seenNames[vocabulary.Name]; duplicate {
			t.Errorf("duplicate vocabulary name %q", vocabulary.Name)
		}
		seenNames[vocabulary.Name] = struct{}{}

		seenValues := make(map[string]struct{}, len(vocabulary.Values))
		for _, value := range vocabulary.Values {
			if value == "" {
				t.Errorf("vocabulary %q has an empty value", vocabulary.Name)
			}
			if _, duplicate := seenValues[value]; duplicate {
				t.Errorf("vocabulary %q repeats value %q", vocabulary.Name, value)
			}
			seenValues[value] = struct{}{}
		}
	}
}

func stringConstantsOfType(t *testing.T, pkgDir string, typeName string) []string {
	t.Helper()
	fileSet := token.NewFileSet()
	packages, err := parser.ParseDir(fileSet, filepath.Clean(pkgDir), nil, 0)
	if err != nil {
		t.Fatalf("parse %s: %v", pkgDir, err)
	}

	var found []string
	for _, pkg := range packages {
		for _, file := range pkg.Files {
			for _, decl := range file.Decls {
				genDecl, ok := decl.(*ast.GenDecl)
				if !ok || genDecl.Tok != token.CONST {
					continue
				}
				for _, spec := range genDecl.Specs {
					valueSpec, ok := spec.(*ast.ValueSpec)
					if !ok {
						continue
					}
					ident, ok := valueSpec.Type.(*ast.Ident)
					if !ok || ident.Name != typeName {
						continue
					}
					for _, value := range valueSpec.Values {
						literal, ok := value.(*ast.BasicLit)
						if !ok || literal.Kind != token.STRING {
							continue
						}
						unquoted, err := strconv.Unquote(literal.Value)
						if err != nil {
							t.Fatalf("unquote %s constant %s: %v", typeName, literal.Value, err)
						}
						found = append(found, unquoted)
					}
				}
			}
		}
	}
	return found
}
