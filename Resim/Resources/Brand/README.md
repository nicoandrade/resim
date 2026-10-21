# Resim brand assets

- `circle-image.svg`: symbol from [Nucleo UI](https://nucleoapp.com/ui-icons).
- `resim-symbol.svg`: the same geometry, white and centered on a 1024-point canvas.
- `../Assets.xcassets/ResimSymbol.imageset`: the same vector symbol used over a SwiftUI gradient in Settings, without the Dock icon's lighting, shadow, or padding.
- `Resim.icon`: editable Icon Composer document with a separate symbol layer, a gold-to-coral gradient, and native glass material and relief.

The source SVG, derived white symbol, Icon Composer layer, and rendered app-icon PNGs retain the Nucleo terms in [Nucleo-COPYRIGHT.txt](../Licenses/Nucleo-COPYRIGHT.txt). They are separate from the MIT license for original Resim source. Preserve the notice with Resim; the icons may not be redistributed as standalone assets.

Open `Resim.icon` in Icon Composer to edit it. From the repository root, `swift scripts/generate-icon.swift` uses Xcode 27's `ictool` to export the default macOS appearance with Design Generation 27 at 4x resolution, then creates the ten AppIcon sizes with standard padding. Before downsampling, it insets the alpha contour by 12 design points to remove the bright outer rim that otherwise breaks into white edge fragments at Finder sizes. The symbol, gradient, and interior glass relief remain from Composer.

Generated PNGs are included so ordinary app builds do not require Icon Composer. The app uses a static icon to retain macOS 14 compatibility. Icon Composer supplies the lighting, reflections, and shadow; the background palette is `#FFB85C` to `#E95470`.
