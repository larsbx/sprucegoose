# Bounded verbatim sample from the preserved
# pi/graphify/repositories/openclaw-system-724bc0c1d6/graphify-out/graph.json.
# source_digest is the SHA-256 of that complete historical artifact.
%{
  source: "graphify/openclaw-system/graph.json",
  source_revision: "historical-2026-07-26",
  source_digest: "sha256:92f2919a9efe6920e47cb57c118fc4eacbbc90875218c8f603f4e3b75ca7fd1a",
  complete?: true,
  nodes: [
    %{
      id: "obsidian_app",
      label: "app.json",
      file_type: "code",
      source_file: ".obsidian/app.json",
      source_location: "L1",
      origin: "ast"
    },
    %{
      id: "obsidian_app_alwaysupdatelinks",
      label: "alwaysUpdateLinks",
      file_type: "code",
      source_file: ".obsidian/app.json",
      source_location: "L2",
      origin: "ast"
    },
    %{
      id: "obsidian_app_newfilelocation",
      label: "newFileLocation",
      file_type: "code",
      source_file: ".obsidian/app.json",
      source_location: "L3",
      origin: "ast"
    },
    %{
      id: "obsidian_app_newfilefolderpath",
      label: "newFileFolderPath",
      file_type: "code",
      source_file: ".obsidian/app.json",
      source_location: "L4",
      origin: "ast"
    },
    %{
      id: "obsidian_app_attachmentfolderpath",
      label: "attachmentFolderPath",
      file_type: "code",
      source_file: ".obsidian/app.json",
      source_location: "L5",
      origin: "ast"
    }
  ],
  edges: [
    %{
      source: "obsidian_app",
      target: "obsidian_app_alwaysupdatelinks",
      relation: "contains",
      confidence: "EXTRACTED",
      source_file: ".obsidian/app.json",
      source_location: "L2",
      origin: "ast"
    },
    %{
      source: "obsidian_app",
      target: "obsidian_app_newfilelocation",
      relation: "contains",
      confidence: "EXTRACTED",
      source_file: ".obsidian/app.json",
      source_location: "L3",
      origin: "ast"
    },
    %{
      source: "obsidian_app",
      target: "obsidian_app_newfilefolderpath",
      relation: "contains",
      confidence: "EXTRACTED",
      source_file: ".obsidian/app.json",
      source_location: "L4",
      origin: "ast"
    },
    %{
      source: "obsidian_app",
      target: "obsidian_app_attachmentfolderpath",
      relation: "contains",
      confidence: "EXTRACTED",
      source_file: ".obsidian/app.json",
      source_location: "L5",
      origin: "ast"
    }
  ]
}
