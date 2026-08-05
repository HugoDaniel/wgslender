//! Enums that arrive as bare strings on the wire.
//!
//! wgslender's JSON spells severities, address spaces, access modes and shader
//! stages as plain lowercase strings, and it may learn new ones. A payload that
//! carries a spelling this version of the crate has never heard of must still
//! parse — one unfamiliar word is not a reason to throw away the whole
//! reflection — so every such enum needs a catch-all variant and a
//! `Deserialize` that falls back to it.
//!
//! serde's own catch-all, `#[serde(other)]`, is only available to internally and
//! adjacently tagged enums, which these are not. Hand-writing a visitor for each
//! one is where the drift would come from, so [`wire_enum`] writes them.

/// Defines a `#[non_exhaustive]` enum over a fixed set of wire spellings, plus
/// the catch-all every wire enum needs.
///
/// The last arm, spelled `_ =>` after the known variants, names the catch-all —
/// the same shape a `match` uses for its wildcard. Generates `as_str`,
/// `Display` and a `Deserialize` that maps an unrecognised string to the
/// catch-all rather than failing.
macro_rules! wire_enum {
    (
        $(#[$meta:meta])*
        $vis:vis enum $name:ident : $expecting:literal {
            $(
                $(#[$variant_meta:meta])*
                $variant:ident => $wire:literal,
            )+
            _ => $unknown:ident => $unknown_wire:literal $(,)?
        }
    ) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        #[non_exhaustive]
        $vis enum $name {
            $(
                $(#[$variant_meta])*
                $variant,
            )+
            #[doc = concat!(
                "A ", $expecting, " this version of the crate does not know.\n\n",
                "The wire may grow spellings; an unfamiliar one parses to this \
                 rather than failing the payload it arrived in.",
            )]
            $unknown,
        }

        impl $name {
            /// The spelling the library uses on the wire.
            #[must_use]
            pub fn as_str(self) -> &'static str {
                match self {
                    $( Self::$variant => $wire, )+
                    Self::$unknown => $unknown_wire,
                }
            }
        }

        impl ::core::fmt::Display for $name {
            fn fmt(&self, f: &mut ::core::fmt::Formatter<'_>) -> ::core::fmt::Result {
                f.write_str(self.as_str())
            }
        }

        impl<'de> ::serde::Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> ::core::result::Result<Self, D::Error>
            where
                D: ::serde::Deserializer<'de>,
            {
                struct Visitor;

                impl ::serde::de::Visitor<'_> for Visitor {
                    type Value = $name;

                    fn expecting(
                        &self,
                        f: &mut ::core::fmt::Formatter<'_>,
                    ) -> ::core::fmt::Result {
                        f.write_str($expecting)
                    }

                    fn visit_str<E>(self, value: &str) -> ::core::result::Result<$name, E>
                    where
                        E: ::serde::de::Error,
                    {
                        ::core::result::Result::Ok(match value {
                            $( $wire => $name::$variant, )+
                            _ => $name::$unknown,
                        })
                    }
                }

                deserializer.deserialize_str(Visitor)
            }
        }
    };
}

pub(crate) use wire_enum;
