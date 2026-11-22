# App icon layers

The layers of `Resources/AppIcon.icon`, the app icon made in Icon Composer. Each is a
1024 x 1024 square SVG, transparent outside its shape, with flat colours and no shadow, gradient
or mask: Icon Composer and macOS mask the icon and add the Liquid Glass effects. Each folder is
one group of the icon.

| File | Shape | Colour |
|---|---|---|
| `Ring/ring-track.svg` | the full countdown ring | white |
| `Ring/ring.svg` | three quarters of the ring, clockwise from the top, round caps | white |
| `Shield/shield.svg` | the shield | white |
| `Shield/keyhole.svg` | the keyhole | `#4338CA` |

## Composing the icon

Icon Composer is opened from Xcode with Xcode > Open Developer Tool > Icon Composer; File > New
makes a document holding a default icon with a solid background. The window has the layers
and groups in the sidebar on the left, the preview in the middle, and the inspectors on the
right.

1. Drag the folders `Ring` and `Shield` from Finder onto the sidebar. Each folder becomes a
   group and each file a layer of it. Delete any default group or layer that was there before.
   In `Shield`, `keyhole` must be above `shield` in the sidebar, since the list is drawn from
   the bottom up; drag it there if it is not.
2. Background: click the icon's name at the top of the sidebar, open the Style inspector
   (upper right), choose All from the Color pop-up menu and Gradient from the Fill pop-up
   menu. Set the From colour to `#4F46E5` and the To colour to `#0EA5E9` (Colors window, Color
   Sliders, RGB, hex field); the background gradient runs from the top to the bottom.
3. Ring track: select the `ring-track` layer and set Opacity, under Color in the Style
   inspector, to about 30 %.
4. Leave Liquid Glass at its defaults; Icon Composer adds it to each group.
5. Check the icon: below the canvas choose macOS and the Default, Dark and Mono appearances
   (Mono > Options holds Light or Dark and Tinted); the Effects buttons above the canvas
   compare 26 and 27.
6. File > Save, name `AppIcon`, in the folder `Resources` of this repository, so the file is
   `Resources/AppIcon.icon`.

`make` compiles `Resources/AppIcon.icon` into the app with Xcode's `actool`.
