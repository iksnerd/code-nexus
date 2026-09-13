// Tailwind v3 build for the LiveView dashboard (replaces the play CDN, which
// compiled classes in the browser and warned against production use).
// Class names must appear as complete strings in these files: helpers like
// value_color/1 return full class names, and app.js toggles literal classes.
module.exports = {
  content: ["../lib/**/*.{ex,heex,exs}", "../priv/static/js/app.js"],
  theme: { extend: {} },
  plugins: [],
};
