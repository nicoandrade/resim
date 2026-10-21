# SVG fixtures

`svg-icon.svg` and `svg-references.svg` are original, synthetic Resim test
illustrations released under CC0-1.0. They contain no downloaded artwork,
photographs, external resources or fonts, and no user-supplied app logo.

The icon deliberately includes indentation and high-precision path coordinates.
The references fixture exercises gradients, clipping, masking, local `use`, CSS,
`currentColor`, UTF-8 text, preserved spaces, and license/metadata retention.
Tests generate hostile and malformed documents in memory instead of shipping
active content as fixture files. The native AppKit renderer independently checks
pixels before and after conservative SVGO serialization.
