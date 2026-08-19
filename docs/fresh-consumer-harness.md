# Fresh-Consumer Harness

The fresh-consumer lane in `tests/test-validation-engine.sh` owns the executable
proof at Touchstone's public consumer boundary. It creates disposable Git
repositories and invokes only the public CLI plus the same declaration engine
used by the pinned required workflow. It is deterministic, offline, and part
of the required test suite.

## Versioned fixtures

`evals/fresh-consumer/v1/` contains one directory per adoption outcome. Each
automatic project-type directory carries only repository facts and an
`expect.tsv` result. The manual directory adds `manual-task`; the ambiguous
directory expects a contract refusal. Adding a supported project type means
adding one fixture directory and expected result—the harness has no
project-type branch.

The current matrix covers the portfolio-backed npm, Python, and Swift shapes,
plus explicit manual tasks and ambiguous mixed roots. For every successful
fixture it proves check and dry-run are read-only, dry-run is deterministic,
apply uses the reviewed plan, the second adoption is current, the schema
parses, all targets and routed steering paths exist, surrounding project prose
survives, and no CLI, runner, registry, sync service, or deletion mechanism is
copied into the consumer. An offline toolchain boundary executes every generated
command, using fakes for the locked npm and Python setup declarations.

## Compatibility and policy lanes

The compatibility lane starts from the oldest supported schema-v1 shape. A
newer runtime validates it without migration; adoption adds the missing tracker
declaration and current marked steering through check/dry-run/apply while
preserving the project-owned validation command. The separate upgrade check
then detects stale managed steering; dry-run remains read-only, apply preserves
the validation contract, and the repeated check is current.

The policy lane runs the local CLI and the required-workflow engine against the
same contract and compares their machine results. Deleting a consumer-local
workflow cannot change the central result. The checked-in policy must still
pin a full source SHA in a different, protected repository. Repository-file
plans continue to report remote policy as a separate operation.

The non-mutation lane snapshots the scratch repository around validation,
installed-CLI help, a Homebrew upgrade adapter, and a mocked read-only PR
status observation. The upgrade may
write only to its isolated installation prefix; it cannot search for or change
a project. AUT-276 will replace the adapter with the released formula without
changing this boundary. Default-branch and dirty apply attempts refuse without
partial files. Every adoption fixture sits beside a committed sentinel
repository; exact sibling inventory and source-checkout snapshots prove the
operation does not cross its declared ownership boundary.
