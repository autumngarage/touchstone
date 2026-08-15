# Adoption V1 Portfolio Corpus

This corpus freezes the repository evidence that bounds automatic adoption in
version 1. `portfolio.tsv` maps each repository to the exact commit and root
files copied byte-for-byte under `repositories/`. The snapshots are inputs,
not expected generated output; detector code may not infer support from shapes
absent here.

`blobs.tsv` records the source commit and Git blob ID for every copied file.
The offline contract test hashes the fixtures and refuses silent corpus drift.

`cases.tsv` defines the initial decision matrix. Portfolio rows use one captured
repository. The two manual controls are deliberate compositions: `none`
presents no supported evidence, while `competing` combines the captured npm and
Python manifests without inventing either external format. Both must select the
explicit manual path rather than a guessed profile.

Lockfiles are retained because their presence is part of the observed shape.
Legacy `.touchstone-config` files are retained because they are the source of
the existing validation commands. Updating any snapshot requires a new exact
head in `portfolio.tsv` and a reviewable refresh of the corresponding bytes.
