---@diagnostic disable: undefined-field
local async = require("neotest.async")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local util = require("neotest-karma.util")
local jest_util = require("neotest-karma.jest-util")
local parameterized_tests = require("neotest-karma.parameterized-tests")

---@class neotest.JestOptions
---@field jestCommand? string|fun(): string
---@field jestConfigFile? string|fun(): string
---@field env? table<string, string>|fun(): table<string, string>
---@field cwd? string|fun(): string
---@field strategy_config? table<string, unknown>|fun(): table<string, unknown>

---@type neotest.Adapter
local adapter = { name = "neotest-karma" }

local rootPackageJson = vim.fn.getcwd() .. "/package.json"

---@return boolean
local function rootProjectHasJestDependency()
  local path = rootPackageJson

  local success, packageJsonContent = pcall(lib.files.read, path)
  if not success then
    print("cannot read package.json")
    return false
  end

  local parsedPackageJson = vim.json.decode(packageJsonContent)

  if parsedPackageJson["dependencies"] then
    for key, _ in pairs(parsedPackageJson["dependencies"]) do
      if key == "karma" then
        return true
      end
    end
  end

  if parsedPackageJson["devDependencies"] then
    for key, _ in pairs(parsedPackageJson["devDependencies"]) do
      if key == "karma" then
        return true
      end
    end
  end

  return false
end

---@param path string
---@return boolean
local function hasJestDependency(path)
  local rootPath = lib.files.match_root_pattern("package.json")(path)

  if not rootPath then
    return false
  end

  local success, packageJsonContent = pcall(lib.files.read, rootPath .. "/package.json")
  if not success then
    print("cannot read package.json")
    return false
  end

  local parsedPackageJson = vim.json.decode(packageJsonContent)

  if parsedPackageJson["dependencies"] then
    for key, _ in pairs(parsedPackageJson["dependencies"]) do
      if key == "karma" then
        return true
      end
    end
  end

  if parsedPackageJson["devDependencies"] then
    for key, _ in pairs(parsedPackageJson["devDependencies"]) do
      if key == "karma" then
        return true
      end
    end
  end

  if parsedPackageJson["scripts"] then
    for _, value in pairs(parsedPackageJson["scripts"]) do
      if value == "karma" then
        return true
      end
    end
  end

  return rootProjectHasJestDependency()
end

adapter.root = function(path)
  return lib.files.match_root_pattern("package.json")(path)
end

---@param file_path? string
---@return boolean
function adapter.is_test_file(file_path)
  if file_path == nil then
    return false
  end
  local is_test_file = false

  if string.match(file_path, "__tests__") then
    is_test_file = true
  end

  for _, x in ipairs({ "spec", "e2e%-spec", "test", "unit", "regression", "integration" }) do
    for _, ext in ipairs({ "js", "jsx", "coffee", "ts", "tsx" }) do
      if string.match(file_path, "%." .. x .. "%." .. ext .. "$") then
        is_test_file = true
        goto matched_pattern
      end
    end
  end
  ::matched_pattern::
  return is_test_file and hasJestDependency(file_path)
end

function adapter.filter_dir(name)
  return name ~= "node_modules"
end

local function get_match_type(captured_nodes)
  if captured_nodes["test.name"] then
    return "test"
  end
  if captured_nodes["namespace.name"] then
    return "namespace"
  end
end

-- Enrich `it.each` tests with metadata about TS node position
function adapter.build_position(file_path, source, captured_nodes)
  local match_type = get_match_type(captured_nodes)
  if not match_type then
    return
  end

  ---@type string
  local name = vim.treesitter.get_node_text(captured_nodes[match_type .. ".name"], source)
  local definition = captured_nodes[match_type .. ".definition"]

  return {
    type = match_type,
    path = file_path,
    name = name,
    range = { definition:range() },
    is_parameterized = captured_nodes["each_property"] and true or false,
  }
end

---@async
---@return neotest.Tree | nil
function adapter.discover_positions(path)
  local query = [[
    ; -- Namespaces --
    ; Matches: `describe('context', () => {})`
    ((call_expression
      function: (identifier) @func_name (#eq? @func_name "describe")
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe('context', function() {})`
    ((call_expression
      function: (identifier) @func_name (#eq? @func_name "describe")
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition
    ; Matches: `describe.only('context', () => {})`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "describe")
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe.only('context', function() {})`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "describe")
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition
    ; Matches: `describe.each(['data'])('context', () => {})`
    ((call_expression
      function: (call_expression
        function: (member_expression
          object: (identifier) @func_name (#any-of? @func_name "describe")
        )
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (arrow_function))
    )) @namespace.definition
    ; Matches: `describe.each(['data'])('context', function() {})`
    ((call_expression
      function: (call_expression
        function: (member_expression
          object: (identifier) @func_name (#any-of? @func_name "describe")
        )
      )
      arguments: (arguments (string (string_fragment) @namespace.name) (function_expression))
    )) @namespace.definition

    ; -- Tests --
    ; Matches: `test('test') / it('test')`
    ((call_expression
      function: (identifier) @func_name (#any-of? @func_name "it" "test")
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
    ; Matches: `test.only('test') / it.only('test')`
    ((call_expression
      function: (member_expression
        object: (identifier) @func_name (#any-of? @func_name "test" "it")
      )
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
    ; Matches: `test.each(['data'])('test') / it.each(['data'])('test')`
    ((call_expression
      function: (call_expression
        function: (member_expression
          object: (identifier) @func_name (#any-of? @func_name "it" "test")
          property: (property_identifier) @each_property (#eq? @each_property "each")
        )
      )
      arguments: (arguments (string (string_fragment) @test.name) [(arrow_function) (function_expression)])
    )) @test.definition
  ]]

  local positions = lib.treesitter.parse_positions(path, query, {
    nested_tests = false,
    build_position = 'require("neotest-karma").build_position',
  })

  local parameterized_tests_positions =
    parameterized_tests.get_parameterized_tests_positions(positions)

  if adapter.jest_test_discovery and #parameterized_tests_positions > 0 then
    parameterized_tests.enrich_positions_with_parameterized_tests(
      positions:data().path,
      parameterized_tests_positions
    )
  end

  return positions
end

local function escapeTestPattern(s)
  return (
    s:gsub("%(", "%\\(")
      :gsub("%)", "%\\)")
      :gsub("%]", "%\\]")
      :gsub("%[", "%\\[")
      :gsub("%*", "%\\*")
      :gsub("%+", "%\\+")
      :gsub("%-", "%\\-")
      :gsub("%?", "%\\?")
      :gsub("%$", "%\\$")
      :gsub("%^", "%\\^")
      :gsub("%/", "%\\/")
      :gsub("%'", "%\\'")
  )
end

local function get_default_strategy_config(strategy, command, cwd)
  local config = {
    dap = function()
      return {
        name = "Debug Jest Tests",
        type = "pwa-node",
        request = "launch",
        args = { unpack(command, 2) },
        runtimeExecutable = command[1],
        console = "integratedTerminal",
        internalConsoleOptions = "neverOpen",
        rootPath = "${workspaceFolder}",
        cwd = cwd or "${workspaceFolder}",
      }
    end,
  }
  if config[strategy] then
    return config[strategy]()
  end
end

local function getEnv(specEnv)
  return specEnv
end

---@param path string
---@return string|nil
local function getCwd(path)
  return nil
end

local function getStrategyConfig(default_strategy_config, args)
  return default_strategy_config
end

local function cleanAnsi(s)
  return s:gsub("\x1b%[%d+;%d+;%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+;%d+m", "")
    :gsub("\x1b%[%d+;%d+m", "")
    :gsub("\x1b%[%d+m", "")
end

local function findErrorPosition(file, errStr)
  -- Look for: /path/to/file.js:123:987
  local regexp = file:gsub("([^%w])", "%%%1") .. "%:(%d+)%:(%d+)"
  local _, _, errLine, errColumn = string.find(errStr, regexp)

  return errLine, errColumn
end

local function parsed_json_to_results(data, output_file, consoleOut)
  local tests = {}

  for _, testResult in pairs(data.testResults) do
    local testFn = testResult.name
    for _, assertionResult in pairs(testResult.assertionResults) do
      local status, name = assertionResult.status, assertionResult.title

      if name == nil then
        logger.error("Failed to find parsed test result ", assertionResult)
        return {}
      end

      local keyid = testFn

      for _, value in ipairs(assertionResult.ancestorTitles) do
        keyid = keyid .. "::" .. value
      end

      keyid = keyid .. "::" .. name

      if status == "pending" then
        status = "skipped"
      end

      tests[keyid] = {
        status = status,
        short = name .. ": " .. status,
        output = consoleOut,
        location = assertionResult.location,
      }

      if not vim.tbl_isempty(assertionResult.failureMessages) then
        local errors = {}

        for i, failMessage in ipairs(assertionResult.failureMessages) do
          local msg = cleanAnsi(failMessage)
          local errorLine, errorColumn = findErrorPosition(testFn, msg)

          errors[i] = {
            line = (errorLine or assertionResult.location.line) - 1,
            column = (errorColumn or 1) - 1,
            message = msg,
          }

          tests[keyid].short = tests[keyid].short .. "\n" .. msg
        end

        tests[keyid].errors = errors
      end
    end
  end

  return tests
end

local function tree_to_list(node, results)
  if node.type == "test" then
    table.insert(results, node)
  end

  for _, child in ipairs(node) do
    tree_to_list(child, results)
  end
end

---@param args neotest.RunArgs
---@return neotest.RunSpec | nil
function adapter.build_spec(args)
  local tree = args.tree

  if not tree then
    return
  end

  local results = {}
  tree_to_list(tree:to_list(), results)

  -- local binary = args.jestCommand or getJestCommand(pos.path)
  -- local config = getJestConfig(pos.path) or "jest.config.js"
  -- local command = vim.split(binary, "%s+")
  -- if util.path.exists(config) then
  --   -- only use config if available
  --   table.insert(command, "--config=" .. config)
  -- end
  --
  -- vim.list_extend(command, {
  --   "--no-coverage",
  --   "--testLocationInResults",
  --   "--verbose",
  --   "--json",
  --   "--outputFile=" .. results_path,
  --   "--testNamePattern=" .. testNamePattern,
  --   "--forceExit",
  --   escapeTestPattern(vim.fs.normalize(pos.path)),
  -- })

  local pos = args.tree:data()
  local command = "npm run test:ci"

  if args.suite then
    -- do nothing
  else
    command = command .. " -- --include=" .. pos.path
  end

  local cwd = getCwd(pos.path)

  -- creating empty file for streaming results
  -- lib.files.write(results_path, "")
  -- local stream_data, stop_stream = util.stream(results_path)

  return {
    command = command,
    cwd = cwd,
    context = {
      suite = args.suite,
      pos = pos,
      results = results,
    },
    -- stream = function()
    --   return function()
    --     local new_results = stream_data()
    --     local ok, parsed = pcall(vim.json.decode, new_results, { luanil = { object = true } })
    --
    --     if not ok or not parsed.testResults then
    --       return {}
    --     end
    --
    --     return parsed_json_to_results(parsed, results_path, nil)
    --   end
    -- end,
    -- strategy = getStrategyConfig(
    --   get_default_strategy_config(args.strategy, command, cwd) or {},
    --   args
    -- ),
    -- env = getEnv(args[2] and args[2].env or {}),
  }
end

local function parse_failing_test_name_lines(file_path)
  local file = io.open(file_path, "r")
  if not file then
    return results
  end

  local lines = {}
  for line in file:lines() do
    if line:find("Executed") then
      -- do nothing
    else
      if line:find("FAILED") then
        if line:find("TOTAL") then
          -- do nothing
        else
          -- ^[[1A^[[2K^[[31mChrome Headless 133.0.0.0 (Mac OS 10.15.7) HoldingBasketComponent should create FAILED^[[39m^M
          table.insert(lines, line)
        end
      end
    end
  end

  file:close()

  return lines
end

local function parse_test_name(node)
  local parts = vim.split(node.id, "::", true)
  local testname = table.concat(parts, "::", 2)
  testname = testname:gsub("::", " ")

  return testname
end

local function test_failed(lines, testname)
  for _, line in ipairs(lines) do
    if line:find(testname) then
      return true
    end
  end

  return false
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result>
function adapter.results(spec, result, tree)
  local results = {}
  local failing_test_name_lines = parse_failing_test_name_lines(result.output)

  for _, node in ipairs(spec.context.results) do
    local testname = parse_test_name(node)
    local testfailed = test_failed(failing_test_name_lines, testname)

    results[node.id] = { status = testfailed and "failed" or "passed" }
  end

  return results
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(adapter, {
  ---@param opts neotest.JestOptions
  __call = function(_, opts)
    if is_callable(opts.jestCommand) then
      getJestCommand = opts.jestCommand
    elseif opts.jestCommand then
      getJestCommand = function()
        return opts.jestCommand
      end
    end
    if is_callable(opts.jestConfigFile) then
      getJestConfig = opts.jestConfigFile
    elseif opts.jestConfigFile then
      getJestConfig = function()
        return opts.jestConfigFile
      end
    end
    if is_callable(opts.env) then
      getEnv = opts.env
    elseif opts.env then
      getEnv = function(specEnv)
        return vim.tbl_extend("force", opts.env, specEnv)
      end
    end
    if is_callable(opts.cwd) then
      getCwd = opts.cwd
    elseif opts.cwd then
      getCwd = function()
        return opts.cwd
      end
    end
    if is_callable(opts.strategy_config) then
      getStrategyConfig = opts.strategy_config
    elseif opts.strategy_config then
      getStrategyConfig = function()
        return opts.strategy_config
      end
    end

    if opts.jest_test_discovery then
      adapter.jest_test_discovery = true
    end

    return adapter
  end,
})

return adapter
