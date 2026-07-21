(lang dune 3.0)

(generate_opam_files true)

(maintainers "TODO")

(authors "TODO")

(license MIT)

(package
 (name sandbox)
 (synopsis "A blank OCaml project in the Jane Street style")
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
