package unifieddiff

import "testing"

func TestWholeFile(t *testing.T) {
	cases := []struct {
		content string
		added   bool
		want    string
	}{
		{"a\n\n- b\n", true, "@@ -0,0 +1,3 @@\n+a\n+\n+- b\n"},
		{"gone", false, "@@ -1,1 +0,0 @@\n-gone\n\\ No newline at end of file\n"},
		{"", true, ""},
	}
	for _, test := range cases {
		if got := WholeFile(test.content, test.added); got != test.want {
			t.Errorf("WholeFile(%q, %v) = %q, want %q", test.content, test.added, got, test.want)
		}
	}
	if got := Hunk(3, 1, 3, 2, []string{" a", "+b"}); got != "@@ -3,1 +3,2 @@\n a\n+b\n" {
		t.Errorf("Hunk = %q", got)
	}
}
