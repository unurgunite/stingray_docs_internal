## 1.6.2

### Added

- **File-scoped `update_types`** — `docscribe update_types path/to/file.rb` updates a single file; the daemon
  accepts `{file}` with priority over `{dir}`. Extra flags (`--rbs`, `--sig-dir`, `--rbs-collection`,
  `--[no-]validate-types`, `--no-rbs`) pass through to both passes.
- **`source` on type mismatches** — every `updated @return`/`@param`/`invalid type` change carries
  `source: "rbs" | "infer" | "syntax"` through JSON, SARIF and daemon responses, so IDE plugins can route RBS
  types to "Update types" and everything else to "Fix YARD".
- **`--[no-]validate-types` flag and `validate_types` config key** — validate YARD types against inferred/RBS
  types and report mismatches.
- **`rbs.collection: true` honored without flags** — plain `check` (CLI, daemon, IDE) auto-discovers the RBS
  collection from `rbs_collection.lock.yaml`, same as `--rbs-collection`.
- **Rescue-branch constant resolution** — rescue bodies referencing constants (e.g. `FALLBACK_TYPE`) infer the
  constant's value type when visible from the method's scope.
- **Per-method failure isolation** — a crashing method is skipped with a stderr warning instead of blanking
  the whole file.

### Changed

- **README updated:** file-scoped `update_types`, `--[no-]validate-types`, `validate_types` config key, daemon
  `update_types` method, `source` field in changes, RBS collection autodiscovery, inference improvements (generics,
  `void` idioms, block types), conditional `@return` stability notes.
- **CI:** docs check runs from the repo root, installs the RBS collection, and skips rubies without RBS (2.7/3.0/3.1);
  `rbs` gem is lazy-required with fallback, `set` is required eagerly.

### Fixed

- **`docscribe config` crash** — the `config` subcommand died with `LoadError` (`cannot load such file --
  docscribe/cli/config`); dispatch now maps `config → config_dump`, with a regression spec covering all 9
  subcommands.
- **`docscribe-client --status` always `not_running`** — the liveness check relied on `UNIXSocket#close`
  return value (`nil`); now a successful connect means alive, missing/stale socket means not running.
- **Missing-collection warning on plain runs** — the `rbs_collection.lock.yaml` nudge now fires without any
  CLI flags (previously gated behind unrelated overrides), in both CLI and daemon paths.
- **`--no-validate-types` ignored** — explicit negation now overrides `validate_types: true` from
  `docscribe.yml` (the default is "not passed", not `false`); audit showed it is the only `--[no-]` flag,
  and `update_types` forwards the negation to both passes.
- **Duplicate files in JSON output** — the same file passed under different spellings (absolute, relative,
  `./`-prefixed, symlinked `/tmp` vs `/private/tmp`) produced several entries and inflated
  `target_file_count`; entries are now merged by normalized path.
- **Machine-readable `type` in JSON/SARIF** — every offense/result carries `type` (`updated_return`,
  `missing_param`, …) alongside `source`, so IDE plugins no longer have to parse it out of `cop_name`.
- **Block-form `to_h` inference** — `arr.each_with_index.to_h { |x, i| ... }` infers `Hash<K, V>` from the
  pair literal (second block parameter is always the `Integer` index) instead of a bare `Array`;
  uninferrable types are honestly reported as `Object` instead of a guessed `String` (same for the
  send-form fallback).
- **Conditional `@return [X] if Error` no longer overwrites the main return type** — kills the check/update_types
  ping-pong.
- **Fallback rescue types are not emitted as noise** — bare `Object` conditionals are skipped.
- **Hash/generic compatibility** — `Hash` vs `Hash<Symbol, Config>`, `Hash[Symbol, untyped]` normalization,
  `**kwargs` alignment (`Hash[Symbol,untyped]` vs `Hash<Symbol,Object>`), `void` for initializers/predicates,
  `String?` vs `String, nil` unions, short names and tuple/array equivalence.
- **Block/operator inference** — `map`/`then` synthesize `Array<inner>`, shovel/`op_asgn`/`csend` resolve via RBS,
  `each_with_index` chains infer element types.
- **YARD parser nil-guards** and trailing-comment normalization (`to_h#foobar` no longer hides diagnostics).
- **`require 'rbs'` crash** on rubies/bundles without the gem (lazy require + fallback list).

## 1.6.0

### Added

- **`docscribe config`** — dump fully resolved configuration (defaults + file + CLI overrides) as YAML.
- **`docscribe coverage`** — documentation coverage report with text table and JSON output formats. Reports percentage
  of documented methods, parameters, and return types per file and overall.
- **`docscribe init --pre-commit`** — generate and install a Git pre-commit hook that checks documentation on staged
  `.rb` files. Supports `--uninstall` and `--dry-run`.
- **Parallel file processing** — thread pool workers process files concurrently. Configurable via `DOCSCRIBE_THREADS`
  env var (default 4). Thread-safe state merge with mutex-guarded `merge_state` helpers.
- **`@!attribute` merge policy (safe mode)** — when a method already has a YARD `@!attribute` doc block, safe mode
  merges only missing parts: adds `@return [Type]` for reader/readwrite access, `@param value [Type]` for
  writer/readwrite access, and missing attr names from `attr_*` calls.
- **Method behavior inference** — `Behavior.analyze` detects predicates (`?`), bang methods (`!`), memoization,
  delegation, and other patterns from AST. `OverloadSelector` selects best-matching method signature from `@overload`
  declarations.
- **`OverloadSelector`** — overload-aware signature selection chooses the best-matching overload based on argument count
  and types with fallback logic.

### Changed

- **README updated:** new sections for `docscribe config`, `coverage`, `init --pre-commit`, and `@!attribute` merge
  policy.
- **Roadmap** updated — v1.6.0 features moved to "What's New" section.

### Fixed

- **`ConfigDump` bug:** `parse_cli_overrides` now slices `:include_file` and `:exclude_file` keys, preventing
  `NoMethodError` in `ConfigBuilder.filter_overrides?`.

## 1.5.1

### Added

- **Server/daemon mode** (`docscribe server`):
    - Start/stop/status subcommand for a persistent background daemon.
    - JSON-RPC 2.0 protocol over Unix socket (`check`, `fix`, `shutdown`, `ping`).
    - Idle timeout (5 minutes) — daemon auto-exits after inactivity.
    - `--server` flag for existing `docscribe` commands to use the daemon transparently.
- **`docscribe-client`** — standalone thin client (`exe/docscribe-client`) for IDE plugins
  and CI. Connects to the daemon without loading the full docscribe gem.
    - `--status` flag to check if the daemon is running (exit code 0/1).
    - `--ping` flag to get version, pid, uptime, and socket path from the daemon.
- **Env invalidation:** daemon socket path includes mtime of `Gemfile.lock` and `rbs_collection.lock.yaml`. Environment
  changes spawn a fresh daemon automatically.
- **LRU file cache:** `Docscribe::LRUCache` (bounded at 1000 entries) caches parsed results per file by mtime, serving
  repeated checks nearly instantly.
- **Rescue-aware type inference for parameters:**
    - `handle_lvar_node` now uses `lookup_lvar_type` which checks both `local_var_types` and `param_types` — rescue body
      returning a parameter defaults to the correct type instead of `Object`.
- **Rescue-aware type inference for explicit receivers:**
    - `resolve_rbs_for_send` falls back to `signature_provider` (project RBS) when `core_rbs_provider` fails — enables
      type resolution for method calls on explicit receivers in rescue bodies.
- **RBS Provider stdlib loading:** `Provider` now loads stdlib libraries (`socket`, `json`, `digest`, etc.) from
  `rbs_collection.lock.yaml`, enabling correct resolution of RBS files that reference stdlib types (e.g. `UNIXSocket`).

### Fixed

- **CLI override leak in daemon:** `apply_cli_overrides` now resets `@effective_config`, `@applied_overrides`, and
  clears `@file_cache` when overrides are `nil` or empty. Previously, stale overrides from a prior request leaked into
  subsequent requests with no overrides.
- **Duplicate `@return` tag in aggressive mode with rescue:** `merge_existing_descriptions!` no longer treats
  machine-generated conditional annotations (e.g. `"if RuntimeError"`) as human-written descriptions — skips
  `return_description` starting with `"if "`.
- **RuboCop compliance:** 2 -> 0 offenses in `lib/docscribe/infer/returns.rb`: extracted
  `resolve_rbs_for_send_with_signature_provider` to fix `Metrics/MethodLength` and `Metrics/ParameterLists`.
- **RBS/Steep:** added signature for `resolve_rbs_for_send_with_signature_provider`.
- **RBS Provider silently returning `Object` for all lookups:** `Provider` failed to load stdlib RBS libraries (
  `socket`, `json`, etc.), causing `NoTypeFoundError` on any sig referencing stdlib types. All `signature_for` calls
  fell back to inference which returned `Object`, silently breaking `docscribe update_types`.
- **Unix socket path exceeding OS limit on macOS:** `Dir.tmpdir` returns a long path under `/var/folders/.../T`, causing
  `ArgumentError: too long unix socket path` (max 104 bytes). The daemon crashed silently on startup. Fixed by falling
  back to `/tmp` when `Dir.tmpdir` exceeds the socket path length limit.

### Changed

- **`docscribe server status` now uses `ping` protocol** for extended info: version, pid, socket path, uptime.
- **Daemon auto-start no longer prints to stderr:** the `"Docscribe: starting server..."` message is only emitted on
  explicit `docscribe server start`, not on implicit auto-start via `--server`.
- **README updated:** new Server mode section documenting daemon, thin client, env invalidation, LRU cache, CLI override
  handling, ping protocol.
- **Editor Integration section** updated to reference `docscribe-client` and daemon.

## 1.5.0

### Added

- **New subcommands:**
    - `docscribe sigs` — generate YARD documentation from RBS type signatures (inverse of `docscribe generate --rbs`)
    - `docscribe rbs` — generate `.rbs` type signature files from existing YARD documentation
    - `docscribe update_types` — two-pass batch update: first pass runs `-AkB --rbs-collection`, second pass runs
      `-aB --rbs-collection` to fill types from RBS signatures while preserving descriptions
    - `docscribe check_for_comments` — scan `.rb` files for placeholder YARD strings (e.g. "Method documentation.", "
      Param documentation.") that indicate undocumented methods; exit 1 if any found
- **Output formats:**
    - `--format json` — RuboCop-compatible JSON output with results, diagnostics, and per-file change lists
    - `--format sarif` — SARIF 2.1 output for integration with GitHub Code Scanning / code quality dashboards
    - `--format text` — explicit text output (default)
    - Dedicated formatter classes in `lib/docscribe/cli/formatters/{text,json,sarif}.rb`
- **CLI flags:**
    - `--keep-descriptions` / `-k` — preserve manually written YARD descriptions (prose, `@note`, `@example`) in
      aggressive mode instead of overwriting them
    - `--quiet` — suppress all explanatory per‑file output; print only final status
    - `--explain` — now enabled by default (was opt-in via `--explain`); shows per-file change reasons on stdout
    - `--progress` — show `[N/total] filename` progress indicator on stderr for large codebases
    - `--no-boilerplate` / `-B` — omit default method message and param header prose from generated docs
    - `--sarif` / `--json` output file path options
- **Exit codes:**
    - `0` — OK, no changes needed
    - `1` — changes applied (safe/aggressive mode) or warnings issued
    - `2` — errors occurred (parse failures, I/O errors)
- **Type inference — new syntax support & better branch handling:**
    - Compound assignment: `@ivar += 123` -> `Integer`, `@ivar ||= Hash.new` -> `Hash`
    - Literal and variable RBS receivers properly resolved (`String.new` uses `String` methods)
    - RHS type propagation through `local_var_types` tracking (`foo = bar; foo.length` -> `Integer`)
    - `begin`/`rescue`/`else`/`end` (`:kwbegin + :rescue`) — unifies body, all rescue branches, and else clause
    - `risky_call rescue :default` (rescue-modifier) — unifies call result with default value
    - `defined?(x)` -> `String?` (returns `nil` or description string)
    - `super` / `super(args)` — RBS lookup on parent method when available, fallback to `Object`
    - `yield` / `yield(args)` — returns block result type (`Object`)
    - Pattern matching `case...in` (`:case_match`) — unifies all `in_pattern` branches + else clause
    - `while`/`until` -> `nil`, `for x in col` -> element type of collection
    - `if`/`else` / `unless`/`else` — unifies both branch types into a union
    - `case`/`when` — unifies all `when` branches + `else` into a union
    - Local variable literal inference: `foo = true` -> `Boolean`, `foo = 42` -> `Integer`, `foo = "str"` -> `String`
    - New test files: `spec/infer/if_else_spec.rb`, `spec/infer/kwbegin_rescue_defined_super_yield_spec.rb`,
      `spec/infer/lvar_spec.rb`, `spec/infer/or_and_spec.rb`
- **RBS integration:**
    - Warning when `--rbs` flag is used without the `rbs` gem installed (shows install instructions on stderr)
    - Clear actionable error message when `--rbs-collection` is used without running
      `bundle exec rbs collection install`
    - `collapse_object_generics` config option — collapses `Array<Object>` -> `Array` when all inner types resolve to
      Object (useful for Hash[Symbol, untyped] -> `Hash<Symbol, Object>` -> `Hash<Symbol>`)
    - Method ID fuzzy matching for RBS signature lookup (matches `foo` against `foo`, `foo?`, `foo=` as appropriate)
    - Per-file RBS signature declarations split alongside their `lib/` sources
- **Configuration:**
    - `skip_anonymous_block_params` config option — skip generating `@param` tags for anonymous `&` (Ruby 3.4+)
    - `emit.include_default_message: true/false` — control default method message header
    - `emit.include_param_documentation: true/false` — control param placeholder text
    - Default config template comments now in English: `"Method documentation."`, `"Param documentation."`
    - All new config keys exposed in `docscribe init` YAML template
- **Post-install message:**
    - `docscribe.gemspec` includes a `post_install_message` thanking the user and linking to the changelog
- **Project assets:**
    - Logo icons added to `assets/icons/` (40×40, 80×80, 128×128, 256×256 pixels) — doc icon with ruby gem
    - Logo Attribution section added to README
    - README logo displays at the top next to badges
- **CI/CD pipeline:**
    - CI now runs `rbs validate` and `steep check` to enforce RBS/stype type correctness
    - CI uses `-aB` instead of `-AkB` for doc idempotency check (avoids infinite `@keep` flag churn)

### Fixed

- **`--help` for subcommands:**
    - `init --help` now shows `BANNER` with description "Generate a starter docscribe.yml configuration file."
    - `generate --help` now properly prints help text instead of silently exiting without output
- **stdout/stderr separation:**
    - Results (per-file change lists, JSON SARIF output) go to **stdout** for piping
    - Diagnostics, warnings, progress go to **stderr**
    - Fail paths list printed to stdout (was stderr) for pipe-friendly CI integration
- **`check_for_comments` false positive:**
    - `comment_line?` now skips example/nested comments matching `/^#\s*#/` (e.g. `  #   # Method documentation.` in
      YARD example blocks)
    - `bundle exec docscribe check_for_comments lib` runs clean on the project itself
- **RuboCop compliance:** 50 -> 0 offenses across `lib/`, `spec/`:
    - Extracted `process_results` in `check_for_comments.rb`
    - Extracted `announce_start`/`announce_complete` in `update_types.rb`
    - Renamed `run_pass_1`/`run_pass_2` -> `run_first_pass`/`run_second_pass`
    - Reordered methods per `SortedMethodsByCall/Waterfall`
    - Fixed spec `ExampleLength`/`MultipleExpectations`/`MessageSpies`/`StubbedMock`
- **Steep type errors:** 47 -> 0 problems:
    - Created `sig/lib/docscribe/cli/update_types.rbs`, `check_for_comments.rbs`, `formatters/{text,json,sarif}.rbs`,
      `rbs_gen.rbs`, `sigs.rbs`
    - Added `BANNER` to `init.rbs`
    - Simplified `raw_or_default` from `reduce` to `Hash#dig` to avoid type mismatch
    - RBS union type syntax: `(String | nil)` for optional return types
    - Fixed nilable type guards across `source_helpers.rb`, `inline_rewriter.rb`, `doc_builder.rb`, `collector.rb`,
      `returns.rb`, `provider.rb`, `generate.rb`
- **`--verbose` output:** now correctly shows per-file change reasons (was silently omitting them in some modes)
- **Ruby 3.0/3.1 CI compatibility:** rbs 4.x requires Ruby ≥ 3.2, excluded via `BUNDLE_WITHOUT`

### Changed

- **`--explain` is default:** users now see explanatory per-file output without needing to opt in. Use `--quiet` to
  suppress.
- **README completely rewritten (563 lines changed):**
    - Restructured: Title -> Badges -> Screenshot/Logo -> Quick Start -> Key Features -> Common Workflows -> Table of
      Contents -> rest
    - 16 GitHub alert blocks (`[!NOTE]`, `[!IMPORTANT]`, `[!WARNING]`, `[!CAUTION]`)
    - Full collapsible configuration reference table (43 keys) with English descriptions and default values
    - Type resolution priority documentation (Sorbet inline -> Sorbet RBI -> RBS sig_dirs+collection -> fallback
      sig_dirs -> AST inference)
    - New sections for all subcommands: `sigs`, `rbs`, `update_types`, `check_for_comments`
    - Tips & tricks section with common flag combinations
    - Roadmap updated with new planned features
- **CLI banners updated** to show all 7 invocation forms: `docscribe [options]`, `init`, `generate`, `sigs`, `rbs`,
  `update_types`, `check_for_comments`
- **YARD type formatter:** uses parentheses `()` for order-dependent lists (tuples) — correct YARD syntax:
  `@return [(String, Array<(Integer, String)>)?]`
- **VERSION bumped** to `1.5.0`
- **`Metrics/ModuleLength` limit raised** in `.rubocop_todo.yml` instead of refactoring (planned for 1.5.1)

### Removed

- Obsolete `lib/docscribe/post_install_message.rb` (logic inlined into `docscribe.gemspec`)

## 1.4.2

### Added

- Architecture module-flow and data-flow diagrams to README.md
- RBS signatures are now split per-file alongside their `lib/` sources (was monolithic `sig/lib/docscribe.rbs`)
- `Steepfile` for `steep check` with `#:` type annotations on safe trailing-comment positions
- `SECURITY.md`, `CONTRIBUTING.md`, issue templates, and PR template for GitHub community standards

### Fixed

- Nilable type warnings in steep (89->57):
    - `source_helpers.rb`: guard `src[...]`, `lines[...]` with `|| ""` / `|| []`
    - `inline_rewriter.rb`: guard `src`/`lines`, `anchor_node`, `param_types`, `visibility`
    - `doc_builder.rb`: guard `type_match[1]`, `m[1]`, `treat_options_keyword_as_hash`, `setup`
    - `collector.rb`: `!!(node && .type)` for `self_node?`, guard `args`
    - `returns.rb`: guard `node.children[]`, `recv`, default kwargs to `unify_types`
    - `provider.rb`: guard `@builder`, fallback `name || :Object`
    - `generate.rb`: guard `output_dir`/`class_name` with `|| '.'` / `|| ''`
- RBS signature fixes: `?collapse_generics` as optional keyword arg, `apply_attr_aggressive!` 2-arg signature
- CLI `dispatch_subcommand` now guarantees `Integer` return (`else 0`)
- CI compatibility for Ruby 3.0/3.1: rbs 4.x requires Ruby ≥ 3.2, excluded via `BUNDLE_WITHOUT`

### Changed

- Major RuboCop compliance sweep across `lib/`, `spec/`, `examples/`
- CLI layer refactored (`options.rb`, `run.rb`, `generate.rb`, `init.rb`, `config_builder.rb`)
- Core rewriter engine refactored (`inline_rewriter.rb`, `collector.rb`, `doc_builder.rb`, `doc_block.rb`,
  `tag_sorter.rb`)
- Type system helpers refactored (`rbs/provider.rb`, `rbs/type_formatter.rb`, `sorbet/base_provider.rb`,
  `infer/returns.rb`)
- Plugin system dispatch simplified (`plugin.rb`, `registry.rb`, `base/collector_plugin.rb`)
- `.rubocop.yml` / `.rubocop_todo.yml` updated with tighter thresholds

## 1.4.1

### Added

- `method_override` key for CollectorPlugins — structured patches (`return_type`, `param_types`, `tags`) that merge
  into the standard DocBuilder pipeline instead of replacing it entirely
- `param_types` override for `@param` tags (merges on top of inference, external sig still wins)
- `tags` override appends arbitrary YARD tags (supports `Docscribe::Plugin::Tag` and plain Hash, incl. string keys)
- Plugin doc normalization: tag-only CollectorPlugin output gets default method message prepended for `def/defs` anchors
- Unit tests for `method_override`: `param_types`, `tags`, priority, string-keyed Hash tags

### Fixed

- `build_override_plugin` test helper not forwarding `tags` to constructor
- `rewrite_with_report` default `config:` (`nil` instead of `Docscribe::Config.new({})`)
- `--include '*/get'` glob pattern now correctly routes as method filter instead of file filter
- `match_pattern?` translates `/` to `#` in glob patterns so `*/get` matches `ApiClient#get`
- ModelAttributes `build_method_docs` processes each class with its own table columns instead of using the first model's
  columns for the entire AST

### Changed

- ModelAttributes plugin converted from `doc:` to `method_override:` (dead code removed)
- ModelAttributes plugin now supports `defs` (class methods) and works with aggressive mode
- ModelAttributes `string_method?` / `infer_string_method_type` now includes `truncate`

## 1.4.0 (2026-05-30)

### Added

- `Registry.register(plugin, priority: N)` for deterministic plugin priority (default `0`)
- CollectorPlugin deduplication — highest-priority plugin wins at each source position
- New example plugins: `RailsAssociations`, `SchemaAttributes`, `ModelAttributes`

### Changed

- Plugin registration now requires explicit `register` call (breaking change for pre-1.4.0)

## 1.3.3 (2026-05-23)

### Fixed

- `--rbs-collection` not reporting type mismatches due to `RBS::DuplicatedDeclarationError` being silently caught
- Collection signatures stored separately from user sig_dirs to prevent poisoning the RBS environment

## 1.3.2 (2026-05-23)

### Added

- `--rbs` and `--rbs-collection` dry-run mode reports type mismatches (shown as `M` in output)

### Fixed

- `RBS::TypeName.parse` compatibility with RBS < 3.9 (Ruby 3.0)
- Safe strategy no longer overwrites manually set `@param` / `@return` types
- `--rbs-collection` flag correctly enables RBS provider

## 1.3.1 (2026-05-09)

### Fixed

- Return type inference for methods with keyword arguments
- Safe mode now updates existing `@return` and `@param` tags when types change
- Consistent `Boolean` inference between `--rbs` and `--rbs-collection`
- Config `DEFAULT` hash now matches template YAML from `docscribe init`

### Added

- Warning when `--rbs*` flags are used on Ruby < 3.0 (falls back to inference)

### Changed

- CI no longer deploys documentation/gem (done locally)

## 1.3.0 (2026-04-27)

### Added

- Plugin system: `TagPlugin` and `CollectorPlugin` base classes
- Enhanced custom RBS parser

## 1.2.1 (2026-03-28)

### Added

- Config options to disable default method descriptions and param placeholder text

## 1.2.0 (2026-03-28)

### Added

- RBS type signature support (`--rbs`, `--rbs-collection`)
- `docscribe init` command
- `attr_*` method documentation generator
- Sorbet signature support via external type providers (`--sorbet`)
- Configurable `@param` / `@return` tag sorting
- `@!attribute` docs for `Struct.new` declarations
- Merge rewrite strategy
- Improved visibility handling (`module_function`, private/public)

### Changed

- Major codebase refactoring
- CLI update strategies simplified

## 1.1.0 (2026-01-16)

### Added

- Support for Ruby 2.7 and Ruby 4.0

## 1.0.0 (2025-11-12)

### Added

- Initial release — inline documentation rewriting for `def` / `def self.` methods
- Safe and aggressive rewrite strategies
- YARD-compatible doc generation with `@param`, `@return`
- RBS inference for parameter and return types
- CLI interface
