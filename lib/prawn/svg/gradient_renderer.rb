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
    prawn.page.resources[:Pattern]["SP#{key}"] = create_gradient_pattern

    prawn.send(:set_color_space, type, :Pattern)
    prawn.renderer.add_content("/SP#{key} #{draw_operator}")
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

  def create_gradient_pattern
    shader_stops =
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
      if shader_stops.length == 1
        shader_stops.first
      else
        prawn.ref!(
          FunctionType: 3, # stitching function
          Domain:       [0.0, 1.0],
          Functions:    shader_stops,
          Bounds:       gradient_element.stops[1..-2].map(&:offset),
          Encode:       [0.0, 1.0] * shader_stops.length
        )
      end

    x1, y1, x2, y2, transformation = gradient_coordinates

    coords =
      if gradient_element.type == :axial
        [0, 0, x2 - x1, y2 - y1]
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

  def gradient_coordinates
    x1, y1 = prawn.send(:map_to_absolute, gradient_element.from)
    x2, y2 = prawn.send(:map_to_absolute, gradient_element.to)

    transformation = prawn.current_transformation_matrix_with_translation(x1, y1)

    [x1, y1, x2, y2, transformation]
  end
end
