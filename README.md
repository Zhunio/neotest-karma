# neotest-karma

This plugin provides a [karma](https://karma-runner.github.io/latest/index.html) adapter for the [Neotest](https://github.com/rcarriga/neotest) framework.

**It is currently a work in progress**.

## Installation

Using packer:

```lua
use({
  'nvim-neotest/neotest',
  requires = {
    ...,
    'Zhunio/neotest-karma',
  }
  config = function()
    require('neotest').setup({
      ...,
      adapters = {
        require('neotest-karma')({
          -- jestCommand = "npm test --",
          -- jestConfigFile = "custom.jest.config.ts",
          -- env = { CI = true },
          -- cwd = function(path)
          --   return vim.fn.getcwd()
          -- end,
        }),
      }
    })
  end
})
```
