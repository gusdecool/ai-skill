---
version: 1
---

Give function parameters and return values explicit type annotations. Give every `const` and `let` one too:
literals, empty values such as `[]`, `{}`, `null` or `new Map()`, destructured values and arrow-function values
included. The one exception is a value assigned directly from a call to a function with a declared return type.

Why: explicit types catch mistakes at compile time and document intent, and the exception keeps the common
typed-call case free of redundant annotations.
