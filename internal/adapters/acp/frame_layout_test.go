package acp

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/Aqothy/maiD/internal/provider/providertest"
)

// An ACP session's frames are kept in maid.db (native_mirror.frames) and are
// the only copy of what History rebuilds the session from, so their encoding
// is part of the file's layout: testdata/frame.golden is that encoding as
// last decided, and this fails when the code would write another.
func TestFrameLayoutGuard(t *testing.T) {
	layout := "native_mirror.frames (acp.frame): every field a frame encodes\n\n" +
		providertest.SampleJSON(t, frame{}) +
		"\n\n`update` is the agent's session/update as go-acp encodes it.\n" +
		"Values stored as text (listed in internal/orchestration/testdata/layout.golden): " +
		strings.Join(providertest.StringTypes(frame{}), " ") + "\n"

	providertest.Golden(t, filepath.Join("testdata", "frame.golden"), layout, `What an ACP frame encodes changed. Frames written before the change are in
maid.db, and nothing else can rebuild their sessions:
  - Frames written before would be misread (a field renamed, removed or
    given another meaning): delete your own maid.db. maiD is unreleased,
    there is nothing to migrate, and orchestration.LayoutVersion stays as it
    is. From the first release such a change ships with a migration instead
    (ROADMAP, "P0: blocks a usable product").
  - Frames written before read the same (a new optional field): nothing to
    do.
Frames that read the same but map to other entries are historyVersion's
business, not this file's.`)
}
