# Kapture SCR — Assets raster para macOS

## Referencia aprobada
El archivo `01_Referencia/KaptureSCR_ORIGINAL_APROBADO_SIN_CAMBIOS.png` es la fuente de referencia intacta. No se han regenerado dibujos ni letras con IA.

## Contenido
- `02_Logo_Horizontal`: PNGs de la referencia, sobre negro, en cuatro tamaños (algunos tamaños son interpolaciones).
- `03_AppIcon`: PNG para Dock/Finder en 16–1024 píxeles e ICNS. Se ha añadido únicamente una baldosa oscura de esquinas redondeadas para obtener el contenedor macOS. **No es el vector maestro**.
- `04_MenuBar`: versiones de 16, 18, 20, 22, 24 y 32 pt, en 1x/2x/3x; variantes blancas Template sobre transparente y de color para fondos oscuros. Son adaptaciones rasterizadas del símbolo aprobado; los interiores negros funcionan como espacio negativo sobre un fondo oscuro.
- `05_Xcode`: appiconset y MenuBarTemplate.imageset con `Contents.json` para Xcode.
- `06_Previews`: vista previa y auditoría de dimensiones y alfa.

## Uso en macOS
- Importa `KaptureSCR.xcassets` en Assets.xcassets. Selecciona el conjunto `AppIcon` como App Icon de tu target macOS.
- En AppKit para la barra de menús, usa por ejemplo:
  `statusItem.button?.image = NSImage(named: "MenuBarTemplate")`
  `statusItem.button?.image?.isTemplate = true`
  `statusItem.button?.image?.size = NSSize(width:18,height:18)`
- El Template es monocromático: macOS lo tiñe según el aspecto del menú; por ello no conserva el dorado. La variante color puede usarse de forma explícita cuando convenga.

## Limitaciones y fidelidad
- El PNG original mide 1692×517. Todo recurso más grande es escalado raster; no gana detalle vectorial.
- El logo original es opaco sobre negro. Se conserva así para fidelidad.
- Un fondo blanco sin cambiar el diseño haría que el sombrero no contrastase correctamente. Por eso no se entrega una variante de marca sobre blanco supuestamente "idéntica".
- El icono de menubar exige quitar fondo y convertir a plantilla, una adaptación funcional, no una copia píxel a píxel.
- El símbolo mostrado en Dock se centra dentro de un contenedor redondeado y no se han modificado sus elementos internos.
