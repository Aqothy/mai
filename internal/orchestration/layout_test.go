package orchestration_test

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/Aqothy/maiD/api/wire"
	"github.com/Aqothy/maiD/internal/orchestration"
	"github.com/Aqothy/maiD/internal/provider"
	"github.com/Aqothy/maiD/internal/provider/providertest"
	"github.com/Aqothy/maiD/internal/store"
)

// storedJSON is every column that keeps a Go type's own JSON.
var storedJSON = []struct {
	column string
	zero   any
}{
	{"threads.workspace", provider.Workspace{}},
	{"threads.contract", orchestration.Contract{}},
	{"threads.policy", orchestration.TreePolicy{}},
	{"participants.settings", []provider.ConfigOptionSelection(nil)},
	{"deliveries.from_actor", orchestration.Actor{}},
	{"deliveries.body", orchestration.MessageBody{}},
	{"deliveries.answer", orchestration.Answer{}},
	{"receipts.result", orchestration.CommandResult{}},
	{"session_entries.entry", provider.Entry{}},
}

// storedRows are the types whose fields are columns.
var storedRows = []any{orchestration.Thread{}, orchestration.Participant{}, orchestration.Turn{}, orchestration.Delivery{}}

// What maid.db holds can't change without someone deciding what happens to
// the files already written: testdata/layout.golden is the layout as last
// decided, and this fails when the code would write another.
func TestLayoutGuard(t *testing.T) {
	var layout strings.Builder
	fmt.Fprintf(&layout, "maid.db layout %d\n\n# Tables and indexes\n\n", orchestration.LayoutVersion)
	file, err := store.Open(filepath.Join(t.TempDir(), "maid.db"), orchestration.LayoutVersion, orchestration.Schema)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	rows, err := file.DB().Query(`SELECT sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY tbl_name, type DESC, name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var statement string
		if err := rows.Scan(&statement); err != nil {
			t.Fatal(err)
		}
		layout.WriteString(statement + ";\n")
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}

	layout.WriteString("\n# JSON in columns: every field the stored type encodes\n")
	stored := slices.Clone(storedRows)
	for _, column := range storedJSON {
		fmt.Fprintf(&layout, "\n%s (%T)\n%s\n", column.column, column.zero, providertest.SampleJSON(t, column.zero))
		stored = append(stored, column.zero)
	}

	layout.WriteString("\n# Values stored as text, in columns and in the JSON above\n\n")
	vocabularies := make(map[string][]string)
	for _, vocabulary := range wire.Vocabularies {
		vocabularies[vocabulary.Name] = vocabulary.Values
	}
	var named, open []string
	for _, zero := range stored {
		named = append(named, providertest.StringTypes(zero)...)
	}
	slices.Sort(named)
	for _, name := range slices.Compact(named) {
		if values, closed := vocabularies[name]; closed {
			fmt.Fprintf(&layout, "%s: %s\n", name, strings.Join(values, " "))
		} else {
			open = append(open, name)
		}
	}
	fmt.Fprintf(&layout, "\nNot closed sets (IDs, or a type api/wire lists no values for): %s\n", strings.Join(open, " "))

	providertest.Golden(t, filepath.Join("testdata", "layout.golden"), layout.String(), `What maid.db holds changed. A file written before the change is still on
people's disks, so decide what happens to it:
  - Rows written before would be misread (a column, a JSON field or a stored
    value renamed, removed or given another meaning): change
    orchestration.LayoutVersion, which sets such a file aside at startup.
    After the first release that is not an option for the ledger: the change
    ships with a migration (ROADMAP, "P0: blocks a usable product").
  - Rows written before read the same (a new optional JSON field, a new
    value): keep the version.`)
}
