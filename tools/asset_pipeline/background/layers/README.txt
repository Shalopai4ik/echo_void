ECHO OF VOID - background plate split into independent layers
=============================================================
Source image : fa75602c-c11e-43ed-bb58-2342f75b8264.png
Source size  : 1672 x 941, 8-bit RGB
Everything in this archive is 1672 x 941 with identical canvas origin, so the
full-canvas layers stack pixel-perfect on top of each other.
All layers are PNG RGBA (straight, non-premultiplied alpha). Where an element
is absent the alpha channel is 0 and the RGB channels are 0 as well, so there
is no white / black / checkerboard fringe.


1. FULL-CANVAS LAYERS (draw in this order, bottom to top)
---------------------------------------------------------
#  file               blend in Godot   content
1  background.png     Mix              Opaque base. Deep-space colour ramp, the
                                       broadest haze and the dark dust lanes.
                                       Contains no clouds, no stars, no objects.
2  nebula.png         Add              The glowing clouds: filaments, clumps,
                                       soft nebula light. Alpha = local glow
                                       strength, RGB = cloud colour.
3  stars_far.png      Add              244 faint point stars (peak luminance
                                       below 0.16).
4  stars_near.png     Add              250 bright point stars plus the two
                                       horizontal lens-flare streaks.
5  planet_glow.png    Add              The atmosphere scattering of the planet:
                                       the bright crescent that hugs the limb
                                       and reaches about 70 px into the sky.
                                       Keep it glued to the planet when moving.
6  planet.png         Mix              The planet body. Solid disc, alpha 255
                                       inside, one antialiased ring outside.
                                       Circle: centre (1854, 656), r = 472, so
                                       only the left cap is inside the frame.
7  asteroids_far.png  Mix              107 small / distant rocks (< 700 px).
8  asteroids_near.png Mix              19 large foreground rocks (>= 700 px).

Approximate coverage of each layer:
  background      1 573 352 px, fully opaque (the whole canvas)
  nebula            402 011 px with alpha > 0
  stars_far          1 259 px
  stars_near         2 841 px
  planet_glow       35 385 px
  planet           167 149 px (165 479 of them fully opaque)
  asteroids_far     18 530 px
  asteroids_near   104 286 px (94 742 fully opaque)

preview.png is the original scene rebuilt from exactly these eight files with
the blend modes above. It is not a copy of the source image.


2. WHY "ADD" FOR THE GLOW LAYERS
--------------------------------
nebula / stars / planet_glow are stored as light, not as paint: alpha holds the
amount of light, RGB holds its colour. Godot's ADD blend computes
dst + src.rgb * src.a, which reproduces the source image exactly. With MIX the
glow would darken the layer beneath it.

Godot 4 import settings per layer:
  - all layers : Process -> Premultiply Alpha = OFF (default)
  - nebula, stars_far, stars_near, planet_glow
               : Rendering -> Blend Mode = Add
  - background, planet, asteroids_far, asteroids_near
               : Rendering -> Blend Mode = Mix
  - Flag Texture -> Filter = On, Mipmaps = On
  - Repeat = Disabled: these plates are not seamless tiles, they are one
    1672 x 941 frame. See the notes at the end if you need tiling.


3. SPRITES (sprites/) - for procedural placement
------------------------------------------------
Every object was also cut out as its own transparent PNG so you can scatter,
scale and rotate them independently instead of reusing the full-canvas layer.
sprites/manifest.json lists, per file: pixel size, area, the source centroid on
the 1672 x 941 canvas, which layer it belongs to and which blend mode to use.

  asteroid_001.png ... asteroid_126.png
      126 rocks, 6 px to 23 049 px, tight crops with 3 px padding.
      Sizes descend with the index. 19 of them are the "near" set, 107 "far".
      The rocks keep the rim lighting of the original frame (light comes from
      the planet at the right), so they blend into the plate from any direction
      as long as you do not mirror them horizontally.
      asteroid_001 / asteroid_002 are multi-rock clusters: in the source these
      rocks physically overlap, so they were kept as one silhouette rather than
      cut into halves.
  planet.png
      290 x 721, the visible cap of the planet. It is cropped by the right edge
      of the canvas exactly as in the source; the full sphere is not present.
  planet_atmosphere.png
      363 x 799, additive. The limb glow, same content as planet_glow.png.
      Place it with the same offset as the planet.
  star_01.png ... star_14.png
      The 14 most distinctive stars (peak luminance 0.98 down to 0.42), each
      with its own halo and diffraction spikes, additive.
  flare_streak.png
      183 x 11, additive. The camera lens-flare streak. It is a photographic
      artefact, so it is easiest to drop this one if you do not want it.


4. VERIFICATION
---------------
The eight full-canvas layers were composited back in the documented order and
compared with the source image, after reading the shipped PNG files:

  mean absolute error   0.281 / 255
  RMSE                  0.00211  (0.54 / 255)
  PSNR                  53.5 dB
  median |error|        0
  99th percentile       1.6 / 255
  pixels above 8/255    112  (0.01 % of the canvas)

Per region: the planet disc, the asteroid bodies and the open sky all sit below
1 / 255 mean error. The largest residuals are single pixels on the brightest
part of the planet limb, where 8-bit rounding of a near-saturated cyan value is
visible. Nothing from the source image disappeared into the wrong layer.

What is deliberately not identical: inside the occluded regions (behind the
planet and the rocks) the base layers hold a harmonic/diffusion reconstruction
of the sky rather than the true hidden pixels - that data does not exist in the
source. If you slide the planet away you will see a smooth, structure-free
continuation of the nebula instead of real clouds. Everywhere else the fill is
only used under fully opaque pixels, so it never shows in the composite.


5. PARALLAX SUGGESTION
----------------------
depth            layer                     motion factor
infinite         background.png            0.02
far              nebula.png                0.05
far              stars_far.png             0.08
mid              stars_near.png            0.15
mid              planet_glow.png           0.25
mid              planet.png                0.25   (must match planet_glow)
near             asteroids_far.png         0.55
foreground       asteroids_near.png        1.00

For an infinite scroll, duplicate each layer side by side; because the plates
are not seamless the seam will be visible, so the usual trick is to scroll the
nebula and star layers at a low factor and let the sprites do the visual work.
