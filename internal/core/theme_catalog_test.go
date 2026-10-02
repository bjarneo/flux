package core

type fakeThemes struct {
	catalog []string
	applied string
	err     error
}

func (f *fakeThemes) Catalog() ([]string, error) { return f.catalog, f.err }
func (f *fakeThemes) Apply(id string) error {
	f.applied = id
	return f.err
}
func (f *fakeThemes) Active() string { return "tokyo-night" }
func (f *fakeThemes) Colors() string { return "[colors]\n" }
