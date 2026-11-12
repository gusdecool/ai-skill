---
name: gd-rest-api-design
description: Use when you design or add a REST endpoint. Covers URL, router, contract and error rules, plus a design-first gate.
license: MIT
metadata:
  author: gusdecool
  version: "1.0"
---

# REST API design

These rules apply to every REST API, whatever the framework. A repo rule may override one, but it must say so
explicitly, for example "Override: this API keeps `POST /packages/{id}/finish` for compatibility".

## Design first

Show the design before writing the endpoint, and wait for the user's OK. Present it as tables or code blocks with:

- the method and path (or the field, for GraphQL and other styles);
- the auth: who may call it, with what scope, role or token;
- the exact request: path params, query params, body and headers, each with its type, required or optional, and
  its constraint;
- the exact response for success and for each error case: status codes, error codes, field names, types and
  nullability;
- a concrete example request and response.

Put the same content in the pull request description. If the design changes during the build, show the updated
version. Why: a wrong shape found after the code exists costs a rewrite of the handler, the contract, the tests and
the client; a review of a short table catches it while it is still cheap to change.

## URLs

- Keep URLs one level deep: `/{resource}` or `/{resource}/{id}`. No nested paths such as `/a/{id}/b/{id}`.
  Why: a path that carries the parent locks the resource to that one parent, so a second parent or a moved record
  becomes a breaking URL change, and every nested segment has to be parsed and authorized again.
- Model an action as its own resource and pass the parent id in the body: `POST /package-finishes` with
  `{ "packageId": "..." }`, not `POST /packages/{id}/finish`. Why: actions as resources are uniform records
  (listable, filterable, auditable) with one URL and one handler each, instead of a verb that only one client knows
  about.
- Use plural, kebab-case resource names: `/package-finishes`, not `/packageFinish` or `/package_finish`. Why: a
  collection and one record then share one name, and kebab-case avoids the case-sensitivity and encoding problems
  that camelCase and underscores bring across clients.
- Version the base path: `/api/v1/package-finishes`. Why: a breaking change ships on `/api/v2` while old clients keep
  working, with no flag or switch inside the code.

## Structure

- One router per resource. Why: the whole surface of a resource stays in one file, so a reviewer and a client see
  every route it exposes at once.
- Keep request and response types and validation schemas in a separate contracts module, not in the router. Why:
  the router moves data, the contract defines it; types and validation that live together cannot drift, and the
  handler and the tests import the same source of truth.
- Use one error handler that returns every error as `{ error, code, fields? }`. Why: a client parses one shape for
  every failure instead of a different one per route, `code` stays stable for program logic while `error` stays
  readable for a human, and `fields` carries per-field validation detail.
