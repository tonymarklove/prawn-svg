class Prawn::SVG::GradientRenderer
  def initialize(prawn, type, gradient_element)
    @prawn = prawn
    @type = type.to_sym
    @gradient_element = gradient_element
  end

  def draw
    key = gradient_element.unique_id

    # Add pattern to the PDF page resources dictionary
    prawn.page.resources[:Pattern] ||= {}
    prawn.page.resources[:Pattern]["Prawn-SVG-Pattern-#{key}"] = create_gradient_pattern

    # Add the transparency ExtGState to the page
    prawn.page.ext_gstates["Prawn-SVG-ExtGState-#{key}"] = create_transparency_graphics_state

    prawn.renderer.add_content("/Prawn-SVG-ExtGState-#{key} gs")
    prawn.send(:set_color_space, type, :Pattern)
    prawn.renderer.add_content("/Prawn-SVG-Pattern-#{key} #{draw_operator}")
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

    shading = prawn.ref!(
      ShadingType: 2,
      ColorSpace:  :DeviceGray,
      Coords:      [0, 0, 20, 0], # FIXME
      Function:    {
        FunctionType: 2,
        Domain:       [0.0, 1.0],
        C0:           [0],
        C1:           [1],
        N:            1
      },
      Extend:      [true, true]
    )

    pattern = prawn.ref!(
      PatternType: 2, # shading pattern
      Shading:     shading
      # Matrix:      transformation
    )

    transparency_group = prawn.ref!(
      Type:      :XObject,
      Subtype:   :Form,
      FormType:  1,
      BBox:      [0, 0, 1200, 800], # FIXME
      Group:     {
        Type: :Group,
        S:    :Transparency,
        I:    true,
        CS:   :DeviceGray
      },
      Resources: {
        Pattern: {
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

    mask = prawn.ref!(
      Type: :Mask,
      S:    :Luminosity,
      G:    transparency_group,
      BC:   [1.0]
    )

    prawn.ref!(
      Type:  :ExtGState,
      SMask: mask,
      AIS:   false
    )
  end

  def create_gradient_pattern
    shader_funcs =
      gradient_element.stops.each_cons(2).map do |first, second|
        prawn.ref!(
          FunctionType: 2,
          Domain:       [0.0, 1.0],
          C0:           prawn.send(:normalize_color, first.color),
          C1:           prawn.send(:normalize_color, second.color),
          N:            1.0
        )
      end

    # If there's only two stops, we can use the single shader.
    # Otherwise we stitch the multiple shaders together.
    shader =
      if shader_funcs.length == 1
        shader_funcs.first
      else
        prawn.ref!(
          FunctionType: 3, # stitching function
          Domain:       [0.0, 1.0],
          Functions:    shader_funcs,
          Bounds:       gradient_element.stops[1..-2].map(&:offset),
          Encode:       [0.0, 1.0] * shader_funcs.length
        )
      end

    transformation = gradient_transform

    puts [gradient_element.from, gradient_element.to].inspect
    puts transformation.inspect

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
      Function:    shader,
      Extend:      [true, true]
    )

    prawn.ref!(
      PatternType: 2, # shading pattern
      Shading:     shading,
      Matrix:      transformation
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
