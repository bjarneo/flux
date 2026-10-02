package core

type themeBackend interface {
	Catalog() ([]string, error)
	Apply(id string) error
	Active() string
	Colors() string
}

func validThemeID(id string) bool {
	if id == "" || id[0] == '-' || id[0] == '.' {
		return false
	}
	for _, c := range id {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}
