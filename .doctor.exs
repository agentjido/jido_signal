%Doctor.Config{
  # Router.DSL is compile-time-only. Its macros are documented on
  # `Jido.Signal.Router.__using__/1`; Doctor does not count those macro docs.
  ignore_modules: [Jido.Signal.Router.DSL],
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 0,
  min_overall_doc_coverage: 100,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 90,
  exception_moduledoc_required: true,
  raise: true,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false
}
