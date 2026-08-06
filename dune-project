(lang dune 3.0)

(generate_opam_files true)

(maintainers "")

(authors "Robyn Wu Clara Yee")

(license MIT)

(package
 (name canary)
 (synopsis
  "Canary: An ocaml visual tool to observe ocaml projects over time")
 (depends
  (ocaml
   (>= 5.2.0))
  dune
  ocaml-lsp-server
  ocamlformat
  (odoc :with-doc)
  core
  ppx_jane
  (expect_test_helpers_core :with-test)))
