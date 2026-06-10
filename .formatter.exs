# SPDX-FileCopyrightText: 2026 ash_lua contributors <https://github.com/ash-project/ash_lua/graphs/contributors>
#
# SPDX-License-Identifier: MIT

spark_locals_without_parens = [
  action: 3,
  action: 4,
  actions: 1,
  argument_names: 1,
  docs_action_name: 1,
  eval_action_name: 1,
  expose?: 1,
  field_names: 1,
  forbidden_fields: 1,
  name: 1,
  namespace: 1,
  namespace: 2,
  otp_app: 1,
  resource: 1,
  resource: 2
]

[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Spark.Formatter],
  import_deps: [:ash],
  locals_without_parens: spark_locals_without_parens,
  export: [
    locals_without_parens: spark_locals_without_parens
  ]
]
