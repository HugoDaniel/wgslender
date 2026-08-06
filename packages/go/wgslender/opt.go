package wgslender

import "encoding/json"

// An Opt holds a value that may not have been given.
//
// It exists because the engine's option objects are override sets: every key is
// absent by default, and an absent key is not the same as a false one. Absent
// means "keep wgslender's default"; false means "turn this off". A plain bool
// field cannot say the first thing, and a *bool says it at the cost of making
// every option a pointer to write and a nil check to read.
//
// The zero Opt is the absent one, which is what makes the surrounding options
// structs useful at their zero value.
//
// Encoding one is only meaningful through a struct field tagged omitzero:
//
//	MinifyWhitespace Opt[bool] `json:"minifyWhitespace,omitzero"`
//
// omitzero consults [Opt.IsZero], so an unset field disappears from the
// document rather than encoding as null.
type Opt[T any] struct {
	v   T
	set bool
}

// Set returns an Opt holding v.
func Set[T any](v T) Opt[T] { return Opt[T]{v: v, set: true} }

// Get returns the value and whether it was ever set. The value is T's zero
// value when it was not.
func (o Opt[T]) Get() (T, bool) { return o.v, o.set }

// IsZero reports whether the value is absent. encoding/json calls it for
// omitzero fields.
func (o Opt[T]) IsZero() bool { return !o.set }

// MarshalJSON encodes the value alone. A field holding an absent Opt should be
// tagged omitzero so this is never reached for one; if it is, the value encodes
// as T's zero value, which is the closest thing to "nothing" JSON has room for
// in a field that insisted on being present.
func (o Opt[T]) MarshalJSON() ([]byte, error) { return json.Marshal(o.v) }

// UnmarshalJSON decodes a present value, marking it set. A key that never
// appears in the document leaves the Opt absent, because Unmarshal does not
// call this at all for a missing key.
func (o *Opt[T]) UnmarshalJSON(b []byte) error {
	if err := json.Unmarshal(b, &o.v); err != nil {
		return err
	}
	o.set = true
	return nil
}
