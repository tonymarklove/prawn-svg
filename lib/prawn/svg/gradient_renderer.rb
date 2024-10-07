class Prawn::SVG::GradientRenderer
  def initialize(prawn, type, gradient_element)
    @prawn = prawn
    @type = type.to_sym
    @gradient_element = gradient_element
  end

  def draw
    key = gradient_element.unique_id

    # If we need transparency, add an ExtGState to the page and enable it.
    if gradient_element.stops.any? { |s| s.opacity < 1 }
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

  attr_reader :prawn, :type, :gradient_element

  def draw_operator
    case type
    when :fill
      'scn'
    when :stroke
      'SCN'
    else
      raise ArgumentError, "unknown type '#{type}'"
    end
  end

  def create_transparency_graphics_state
    prawn.renderer.min_version(1.4)

    offsets = gradient_element.stops.map(&:offset)
    opacity_stops = gradient_element.stops.map { |stop| [stop.opacity] }

    shading_func = create_shading_function(offsets, opacity_stops)

    p0 = gradient_element.matrix * Vector[0, 0, 1]
    p1 = gradient_element.matrix * Vector[1, 0, 1]

    shading = prawn.ref!(
      ShadingType: 2,
      ColorSpace:  :DeviceGray,
      Coords:      [p0[0], p0[1], p1[0], p1[1]], # FIXME
      Function:    shading_func,
      Extend:      [true, true]
    )

    transform = gradient_element.matrix

    # FIXME remove?
    pattern = prawn.ref!(
      PatternType: 2, # shading pattern
      Shading:     shading,
      # Matrix:      transform.to_a[0..1].transpose.flatten
    )

    transparency_group = prawn.ref!(
      Type:      :XObject,
      Subtype:   :Form,
      FormType:  1,
      BBox:      prawn.state.page.dimensions, # FIXME?
      Group:     {
        Type: :Group,
        S:    :Transparency,
        I:    true,
        CS:   :DeviceGray
      },
      Resources: {
        Pattern: { # FIXME remove?
          'TGP01' => pattern
        },
        Shading: {
          'TGS01' => shading
        }
      }
    )

    transparency_group.stream << begin
      # box = PDF::Core.real_params([0, 760, 1200, 800])

      <<~CMDS.strip
        /TGS01 sh
      CMDS

      # <<~CMDS.strip
      #   /DeviceGrey cs
      #   0.53333 scn
      #   0.0 780.0 20.0 20.0 re
      #   f
      # CMDS

      # <<~CMDS.strip
      #   /Pattern cs
      #   /TGP01 scn
      #   0.0 780.0 20.0 20.0 re
      #   f
      # CMDS
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
    offsets = gradient_element.stops.map(&:offset)
    color_stops = gradient_element.stops.map { |stop| prawn.send(:normalize_color, stop.color) }

    shading_func = create_shading_function(offsets, color_stops)

    transformation = gradient_transform

    # puts [gradient_element.from, gradient_element.to].inspect
    # puts transformation.inspect

    # transformation = [92.30769230769229, 0.0, 0.0, 92.30769230769229, 18.46153846153846, -2892.315384615384]

    coords =
      if gradient_element.type == :axial
        # [0, 0, x2 - x1, y2 - y1]
        [gradient_element.from, gradient_element.to].flatten
      else
        [0, 0, gradient_element.r1, x2 - x1, y2 - y1, gradient_element.r2]
      end

    shading = prawn.ref!(
      ShadingType: gradient_element.type == :axial ? 2 : 3,
      ColorSpace:  prawn.send(:color_space, gradient_element.stops.first.color),
      Coords:      coords,
      Function:    shading_func,
      Extend:      [true, true]
    )

    prawn.ref!(
      PatternType: 2, # shading pattern
      Shading:     shading,
      Matrix:      transformation
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
    x1, y1 = prawn.send(:map_to_absolute, gradient_element.from)

    tm = prawn.current_transformation_matrix_with_translation #(x1, y1)

    mat = Matrix[
      [tm[0], tm[2], tm[4]],
      [tm[1], tm[3], tm[5]],
      [0.0, 0.0, 1.0]
    ]

    result = mat * gradient_element.matrix

    result.to_a[0..1].transpose.flatten
  end
end
