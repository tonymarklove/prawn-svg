class Prawn::SVG::GradientRenderer
  def initialize(prawn, type, gradient)
    @prawn = prawn
    @type = type.to_sym
    @gradient = gradient
  end

  def draw
    key = gradient.key

    # If we need transparency, add an ExtGState to the page and enable it.
    if gradient.stops.any? { |s| s.opacity < 1 }
      prawn.page.ext_gstates["PSVG-ExtGState-#{key}"] = create_transparency_graphics_state
      prawn.renderer.add_content("/PSVG-ExtGState-#{key} gs")
    end

    # Add pattern to the PDF page resources dictionary.
    prawn.page.resources[:Pattern] ||= {}
    prawn.page.resources[:Pattern]["PSVG-Pattern-#{key}"] = create_gradient_pattern

    prawn.send(:set_color_space, type, :Pattern)
    prawn.renderer.add_content("/PSVG-Pattern-#{key} #{draw_operator}")
  end

  private

  attr_reader :prawn, :type, :gradient

  def draw_operator
    type == :fill ? 'scn' : 'SCN'
  end

  def gradient_coordinates
    if gradient.type == :axial
      [*gradient.from, *gradient.to]
    else
      [*gradient.from, gradient.r1, *gradient.to, gradient.r2]
    end
  end

  def create_transparency_graphics_state
    prawn.renderer.min_version(1.4)

    offsets = gradient.stops.map(&:offset)
    opacity_stops = gradient.stops.map { |stop| [stop.opacity] }

    transform = gradient.matrix.to_a[0..1].transpose.flatten

    transparency_group = prawn.ref!(
      Type:      :XObject,
      Subtype:   :Form,
      BBox:      prawn.state.page.dimensions, # FIXME?
      Group:     {
        Type: :Group,
        S:    :Transparency,
        I:    true,
        CS:   :DeviceGray
      },
      Resources: {
        Pattern: {
          'TGP01' => {
            PatternType: 2,
            Matrix:      transform,
            Shading:     {
              ShadingType: gradient.type == :axial ? 2 : 3,
              ColorSpace:  :DeviceGray,
              Coords:      gradient_coordinates,
              Function:    create_shading_function(offsets, opacity_stops),
              Extend:      [true, true]
            }
          }
        }
      }
    )

    transparency_group.stream << begin
      box = PDF::Core.real_params(prawn.state.page.dimensions)

      <<~CMDS.strip
        /Pattern cs
        /TGP01 scn
        #{box} re
        f
      CMDS
    end

    prawn.ref!(
      Type:  :ExtGState,
      SMask: {
        Type: :Mask,
        S:    :Luminosity,
        G:    transparency_group
      },
      AIS:   false
    )
  end

  def create_gradient_pattern
    offsets = gradient.stops.map(&:offset)
    color_stops = gradient.stops.map { |stop| prawn.send(:normalize_color, stop.color) }

    prawn.ref!(
      PatternType: 2,
      Shading:     {
        ShadingType: gradient.type == :axial ? 2 : 3,
        ColorSpace:  prawn.send(:color_space, gradient.stops.first.color),
        Coords:      gradient_coordinates,
        Function:    create_shading_function(offsets, color_stops),
        Extend:      [true, true]
      },
      Matrix:      gradient_transform
    )
  end

  def create_shading_function(offsets, color_stops)
    linear_funcs = color_stops.each_cons(2).map do |c0, c1|
      prawn.ref!(FunctionType: 2, Domain: [0.0, 1.0], C0: c0, C1: c1, N: 1.0)
    end

    # If there's only two stops, we can use the single shader.
    return linear_funcs.first if linear_funcs.length == 1

    # Otherwise we stitch the multiple shaders together.
    prawn.ref!(
      FunctionType: 3, # stitching function
      Domain:       [0.0, 1.0],
      Functions:    linear_funcs,
      Bounds:       offsets[1..-2],
      Encode:       [0.0, 1.0] * linear_funcs.length
    )
  end

  def gradient_transform
    x1, y1 = prawn.send(:map_to_absolute, gradient.from)

    tm = prawn.current_transformation_matrix_with_translation #(x1, y1)

    mat = Matrix[
      [tm[0], tm[2], tm[4]],
      [tm[1], tm[3], tm[5]],
      [0.0, 0.0, 1.0]
    ]

    result = mat * gradient.matrix

    result.to_a[0..1].transpose.flatten
  end
end
