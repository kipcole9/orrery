# Which projects the dashboard covers.
#
# A project is a family of repositories in one directory under :root — the
# dashboard shows one table per project. Every git working tree inside the
# directory is picked up automatically, so a new repository appears on the
# dashboard as soon as it is cloned into the right place — nothing here needs
# editing for that.
#
# To add a project, add an entry to :groups (the key keeps its old name so the
# report format is unchanged). To pin a project to an explicit set of
# repositories rather than everything in a directory, give it a :repos list of
# paths relative to :root. To leave a repository out, add its path to :exclude.

%{
  root: "~/Development",
  groups: [
    %{
      name: "Unicode",
      dir: "unicode",
      blurb: "Unicode character data, properties, sets and transforms"
    },
    %{
      name: "Localize",
      dir: "localize",
      blurb: "CLDR-backed localisation: formatting, calendars, names, addresses"
    },
    %{
      name: "Image",
      dir: "image",
      blurb: "Image processing over libvips, plus colour science"
    },
    %{
      name: "Text",
      dir: "text",
      blurb: "Natural language detection, stemming and corpora"
    },
    %{
      name: "Tempo",
      dir: "tempo",
      blurb: "ISO 8601-2 temporal reasoning, calendars and scheduling"
    },
    %{
      name: "Money",
      dir: "money",
      blurb: "Currency arithmetic, formatting, persistence and tax"
    },
    %{
      name: "Other",
      dir: ".",
      blurb: "Repositories that do not belong to a project",
      repos: ["astro", "url", "orrery", "tz_world"]
    }
  ],

  # Paths relative to :root that should never appear on the dashboard.
  # Vendored upstream sources, generated data and the GitHub organisation
  # profile repositories (the `.github` clones) live here.
  exclude: [
    "localize/icu",
    "localize/elixir-localize",
    "unicode/elixir-unicode",
    "image/elixir_image",
    "money/elixir-money",
    "localize/messageformat.dev",
    "localize/name-dataset",
    "image/libvips",
    "image/lensfun",
    "image/colour_science",
    "text/snowball"
  ]
}
