# Size-Based Classification

Use size categories to drive smart placement and interaction tuning:

- SMALL: < 1m objects (grills, decor)
- MEDIUM: 1–2m objects (tables, chairs)
- BIG: > 2m objects (pergolas, gazebos)

Guidelines:
- SMALL → distance ~1.5–2.0m
- MEDIUM → distance ~2.5–3.0m
- BIG → distance ~4.0–6.0m

API:
- addNodeWithSmartPlacement(node, sizeType: 'SMALL'|'MEDIUM'|'BIG')
- Utilities: ARObjectPlacementUtils (distance/height/collision sizing)

Examples:
- examples/smart_placement_demo.dart
- example_app/lib/pergola_placement_example_fixed.dart
