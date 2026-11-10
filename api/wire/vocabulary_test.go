package wire

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"
)

// goVocabularyTypes points each vocabulary at the Go type whose constants
// define it; coverage is then derived from the source.
var goVocabularyTypes = map[string]struct{ pkgDir, typeName string }{
	"CommandErrorCode":           {"../../internal/orchestration", "ErrorCode"},
	"ACPAgentSource":             {".", "ACPAgentSource"},
	"ACPAgentState":              {".", "ACPAgentState"},
	"ACPAgentBlocker":            {".", "ACPAgentBlocker"},
	"ThreadStatus":               {"../../internal/orchestration", "ThreadStatus"},
	"OriginKind":                 {"../../internal/orchestration", "OriginKind"},
	"Hold":                       {"../../internal/orchestration", "Hold"},
	"StartedBy":                  {"../../internal/orchestration", "StartedBy"},
	"DeliveryKind":               {"../../internal/orchestration", "DeliveryKind"},
	"DeliveryMode":               {"../../internal/orchestration", "DeliveryMode"},
	"DeliveryState":              {"../../internal/orchestration", "DeliveryState"},
	"ActorKind":                  {"../../internal/orchestration", "ActorKind"},
	"WakeMode":                   {"../../internal/orchestration", "WakeMode"},
	"ThreadEventKind":            {"../../internal/orchestration", "ThreadEventKind"},
	"ThreadListKind":             {"../../internal/orchestration", "ThreadListKind"},
	"TurnState":                  {"../../internal/provider", "TurnState"},
	"StreamKind":                 {"../../internal/provider", "StreamKind"},
	"EnvelopeKind":               {"../../internal/provider", "EnvelopeKind"},
	"HistoryQuality":             {"../../internal/provider", "HistoryQuality"},
	"ApprovalDecision":           {"../../internal/provider", "ApprovalDecision"},
	"QuestionKind":               {"../../internal/provider", "QuestionKind"},
	"OutputFormat":               {"../../internal/provider", "OutputFormat"},
	"StopReason":                 {"../../internal/provider", "StopReason"},
	"AttachmentKind":             {"../../internal/provider", "AttachmentKind"},
	"AuthKind":                   {"../../internal/provider", "AuthKind"},
	"AccessLevel":                {"../../internal/provider", "AccessLevel"},
	"ItemKind":                   {"../../internal/provider", "ItemKind"},
	"ItemStatus":                 {"../../internal/provider", "ItemStatus"},
	"GoalStatus":                 {"../../internal/provider", "GoalStatus"},
	"ToolAction":                 {"../../internal/provider", "ToolAction"},
	"FileChangeKind":             {"../../internal/provider", "FileChangeKind"},
	"ConfigOptionType":           {"../../internal/provider", "ConfigOptionType"},
	"ConfigOptionCategory":       {"../../internal/provider", "ConfigOptionCategory"},
	"PlanEntryStatus":            {"../../internal/provider", "PlanEntryStatus"},
	"PlanEntryPriority":          {"../../internal/provider", "PlanEntryPriority"},
	"InstanceStatus":             {"../../internal/provider", "InstanceStatus"},
	"AuthStatus":                 {"../../internal/provider", "AuthStatus"},
	"TerminalListStreamItemKind": {".", "TerminalListStreamItemKind"},
	"TerminalProgramState":       {"../../internal/terminal", "ProgramState"},
	"TerminalProgramNeed":        {"../../internal/terminal", "ProgramNeed"},
	"TerminalColorScheme":        {"../../internal/terminal", "ColorScheme"},
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

func stringConstantsOfType(t *testing.T, pkgDir string, typeName string) []string {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(pkgDir, "*.go"))
	if err != nil {
		t.Fatalf("list %s: %v", pkgDir, err)
	}
	fileSet := token.NewFileSet()
	var found []string
	for _, path := range paths {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fileSet, path, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
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
					// An empty constant is the field's absence on the wire
					// (omitempty), not a value clients name.
					if unquoted != "" {
						found = append(found, unquoted)
					}
				}
			}
		}
	}
	return found
}
