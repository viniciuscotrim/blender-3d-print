# SolidFill — continuar de onde parou

Cole esta instrução na nova sessão: **"Leia CONTINUAR.md e execute a tarefa pendente."**

## Projeto
App macOS (Swift/SwiftUI + SceneKit) + CLI `solidfill`. Pasta: `/Volumes/APFS3/AI Access/Blender/SolidFill`.
Build do app: `./scripts/build_app.sh` (gera `SolidFill.app`). Build rápido: `swift build -c release`.
Alvos: `SolidFillCore` (biblioteca), `solidfill` (CLI), `SolidFillApp` (UI). Respostas ao usuário em português.

## O que já foi implementado
- Zoom na vista 3D e na aba Corte (scroll, botões, pinça); zoom na 3D vai para o ponto sob o ponteiro (hit test) e esse ponto vira o pivô de rotação.
- Navegação 3D: botão esquerdo = pan, direito (ou Ctrl+clique) = gira 360°, botão do meio = pan (`ZoomSCNView` em `ContentView.swift`).
- 3D do Resultado: slider de camadas (eixo X/Y/Z) com corte por shader + tampa texturizada; toggle "Cores" (azul = preenchido, cinza = superfície original).
- Preview simplificado por agrupamento de vértices (padrão) com toggle; contador de triângulos no canto da vista 3D.
- Modo "Somente interior (preservar exterior)": classifica regiões seladas por visibilidade (64 direções) e restaura as externas. Parâmetros: selar aberturas, visibilidade máx. CLI: `--interior`, `--visibility`.
- Suportes internos (`Support.swift`, `Filler.swift`): cavidades ficam vazias e recebem suporte só sob overhangs. Parâmetros no estilo Bambu (ângulo limite, padrão retilíneo/grade/favo, espaçamento, ângulo, largura da linha, Z superior/inferior, XY, camadas e espaçamento de interface, altura da camada) + decisão por cavidade: "Vão máx. de ponte (mm)" e "Preencher cavidades em ponte". CLI: `--support`, `--bridge`, `--bridge-empty`, etc.
- Estados de célula novos em `VoxelGrid.swift`: `void` = 9, `support` = 10, `hollow` = 11.

## CONCLUÍDO (aguarda teste do usuário no Bambu Studio): exportar 3MF compatível
**Problema:** ao abrir o 3MF exportado no Bambu Studio, ele avisa que as configs estão erradas e importa só a geometria.
**Causa (confirmada em `~/Downloads/Fachada.3mf` vs `~/Downloads/Fachada_solido_support.3mf`):**
- O original é um projeto Bambu Studio 02.08.02.61, com `Metadata/project_settings.config`, `model_settings.config`, `slice_info.config`, `cut_information.xml`, `filament_sequence.json`, miniaturas `plate_*.png`, `3D/Objects/object_1.model` (572 MB) e `3dmodel.model` com `BambuStudio:3mfVersion`.
- Nosso `write3MF` (`Sources/SolidFillCore/MeshIO.swift`, ~linha 162) grava só `[Content_Types].xml`, `_rels/.rels` e `3D/3dmodel.model` com `Application=SolidFill`.

**Plano:**
1. `MeshWriter.write` e `write3MF` ganham `template: URL?` (o arquivo de entrada). `AppModel.export()` e `Sources/solidfill/main.swift` passam a URL de entrada quando é .3mf.
2. Se o template for um zip com `Metadata/project_settings.config`: copiar os arquivos pequenos de `Metadata/` (configs, pngs, json) **sem ler `3D/Objects/*.model`** (usar o leitor em `ZipIO.swift`, entrada por entrada).
3. Gravar a malha nova (já em coordenadas de mundo, pois `ThreeMFReader` aplicou as transformações) em `3D/Objects/object_1.model` no formato Bambu (`xmlns:BambuStudio`, `xmlns:p`, `BambuStudio:3mfVersion=1`, objeto id=1 com `p:UUID`), e um `3dmodel.model` novo com objeto id=2 (`<components>` apontando `p:path="/3D/Objects/object_1.model"`, transform identidade) e `<build>` com `<item objectid="2" transform=identidade printable="1"/>`. Copiar `Application` e `BambuStudio:3mfVersion` do template.
4. Gerar `Metadata/model_settings.config` novo: um `<object id="2">` (name = nome do arquivo, extruder 1, `face_count` atualizado), um `<part id="1" subtype="normal_part">` com `matrix` identidade e `mesh_stat`, um `<plate>` copiando as chaves `filament_*` e os arquivos de miniatura do template, e `<assemble>` com transformações identidade. Referências a miniaturas só se o arquivo existir.
5. Atualizar `_rels/.rels` (modelo + miniaturas) e `[Content_Types].xml` (rels, model, png) no estilo do original.
6. Se a entrada NÃO for projeto Bambu (STL/OBJ/3MF genérico): manter o 3MF simples atual, sem simular que veio do Bambu.
7. Testar: exportar `~/Downloads/Fachada.3mf` processado e conferir `unzip -l` / estrutura XML contra o original. Pedir ao usuário para abrir no Bambu Studio (não dá para testar aqui).

Observações: a malha de suporte vai como geometria dentro do objeto (não existe suporte "do slicer"); as configs de suporte do projeto original (`support_*`, `enable_support`) são mantidas como estavam.

## Acesso
Na sessão anterior o acesso a `/Volumes/APFS3` e depois a `~/Downloads` passou a dar "Operation not permitted". Se acontecer de novo: iniciar `claude` com `cd` dentro da pasta do projeto, ou usar `/add-dir`.
