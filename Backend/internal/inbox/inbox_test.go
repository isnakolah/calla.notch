package inbox

import "testing"

func TestValidate(t *testing.T) {
	ok := map[string]string{
		"notify":        `{"title":"hi"}`,
		"replace_turns": `{"call_id":"call-12345678","revision":1,"turns":[]}`,
		"pull_bundle":   `{"bundle_id":"standup-context","dest":"context"}`,
	}
	for k, p := range ok {
		if err := Validate(k, []byte(p)); err != nil {
			t.Errorf("%s: %v", k, err)
		}
	}
	bad := map[string][2]string{
		"unknown kind":   {"run_shell", `{"cmd":"rm -rf /"}`},
		"missing field":  {"notify", `{"body":"x"}`},
		"not an object":  {"notify", `["title"]`},
		"bad call id":    {"upsert_recap", `{"call_id":"../../x","markdown":"m"}`},
		"bad bundle id":  {"pull_bundle", `{"bundle_id":"../x","dest":"context"}`},
		"bad bundle dst": {"pull_bundle", `{"bundle_id":"abc","dest":"/Applications"}`},
	}
	for name, c := range bad {
		if Validate(c[0], []byte(c[1])) == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
