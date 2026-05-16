const js = require("@eslint/js");
const globals = require("globals");

module.exports = [
  js.configs.recommended,
  {
    languageOptions: {
      ecmaVersion: 2021,
      sourceType: "commonjs",
      globals: {
        ...globals.node,
      },
    },
    rules: {
      "no-unused-vars": ["warn", {
        argsIgnorePattern: "^_|^next$|^err$|^error$",
        varsIgnorePattern: "^_",
        caughtErrors: "none",
      }],
      "no-console": "off",
    },
  },
  {
    files: ["**/*.test.js", "**/test/**/*.js", "**/__tests__/**/*.js"],
    languageOptions: {
      globals: {
        ...globals.jest,
      },
    },
  },
  {
    ignores: ["services/frontend/**", "**/node_modules/**", "**/coverage/**"],
  },
];
