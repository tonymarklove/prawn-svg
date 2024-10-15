class Prawn::SVG::GradientRenderer
  include Prawn::SVG::TransformUtils

  def initialize(prawn, draw_type, from:, to:, stops:, matrix: nil, r1: nil, r2: nil, wrap: :pad)
    @prawn = prawn
    @draw_type = draw_type
    @from = from
    @to = to

    if r1
      @shading_type = 3
      @coordinates = [*from, r1, *to, r2]
    else
      @shading_type = 2
      @coordinates = [*from, *to]
    end

    @stop_offsets, @color_stops, @opacity_stops = process_stop_arguments(stops)
    @gradient_matrix = matrix ? load_matrix(matrix) : Matrix.identity(3)
    @wrap = wrap
  end

  def draw
    # If we need transparency, add an ExtGState to the page and enable it.
    if opacity_stops
      prawn.page.ext_gstates["PSVG-ExtGState-#{key}"] = create_transparency_graphics_state
      prawn.renderer.add_content("/PSVG-ExtGState-#{key} gs")
    end

    # Add pattern to the PDF page resources dictionary.
    prawn.page.resources[:Pattern] ||= {}
    prawn.page.resources[:Pattern]["PSVG-Pattern-#{key}"] = create_gradient_pattern

    # Finally set the pattern with the drawing operator for fill/stroke.
    prawn.send(:set_color_space, draw_type, :Pattern)
    draw_operator = draw_type == :fill ? 'scn' : 'SCN'
    prawn.renderer.add_content("/PSVG-Pattern-#{key} #{draw_operator}")
  end

  private

  attr_reader :prawn, :draw_type, :shading_type, :coordinates, :from, :to,
    :stop_offsets, :color_stops, :opacity_stops, :gradient_matrix, :wrap

  def key
    @key ||= Digest::SHA1.hexdigest([
      draw_type, shading_type, coordinates, stop_offsets, color_stops, opacity_stops, gradient_matrix
    ].join)
  end

  def process_stop_arguments(stops)
    stop_offsets = []
    color_stops = []
    opacity_stops = []

    transparency = false

    stops.each do |stop|
      opacity = stop[:opacity] || 1.0

      transparency = true if opacity < 1

      stop_offsets << stop[:offset]
      color_stops << prawn.send(:normalize_color, stop[:color])
      opacity_stops << [opacity]
    end

    opacity_stops = nil unless transparency

    [stop_offsets, color_stops, opacity_stops]
  end

  def create_transparency_graphics_state
    prawn.renderer.min_version(1.4)

    repeat_count, transform = compute_wrapping(wrap, from, to, current_pdf_translation * gradient_matrix)

    transparency_group = prawn.ref!(
      Type:      :XObject,
      Subtype:   :Form,
      BBox:      prawn.state.page.dimensions,
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
            Matrix:      matrix_for_pdf(transform),
            Shading:     {
              ShadingType: shading_type,
              ColorSpace:  :DeviceGray,
              Coords:      coordinates,
              Domain:      [0, repeat_count],
              Function:    create_shading_function(stop_offsets, opacity_stops, wrap, repeat_count),
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
    repeat_count, transform = compute_wrapping(wrap, from, to, current_pdf_transform * gradient_matrix)

    prawn.ref!(
      PatternType: 2,
      Matrix:      matrix_for_pdf(transform),
      Shading:     {
        ShadingType: shading_type,
        ColorSpace:  prawn.send(:color_space, color_stops.first),
        Coords:      coordinates,
        Domain:      [0, repeat_count],
        Function:    create_shading_function(stop_offsets, color_stops, wrap, repeat_count),
        Extend:      [true, true]
      }
    )
  end

  def create_shading_function(offsets, stop_values, wrap = :pad, repeat_count = 1)
    gradient_func = create_shading_function_for_stops(offsets, stop_values)

    # Return the gradient function if there is no need to repeat.
    return gradient_func if wrap == :pad

    even_odd_encode = wrap == :reflect ? [[1, 0], [0, 1]] : [[0, 1], [0, 1]]
    encode = repeat_count.times.flat_map { |num| even_odd_encode[num % 2] }

    prawn.ref!(
      FunctionType: 3, # stitching function
      Domain:       [0, repeat_count],
      Functions:    Array.new(repeat_count, gradient_func),
      Bounds:       Range.new(1, repeat_count - 1).to_a,
      Encode:       encode
    )
  end

  def create_shading_function_for_stops(offsets, stop_values)
    linear_funcs = stop_values.each_cons(2).map do |c0, c1|
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

  def current_pdf_transform
    @current_pdf_transform ||= load_matrix(
      prawn.current_transformation_matrix_with_translation(*prawn.bounds.anchor)
    )
  end

  def current_pdf_translation
    @current_pdf_translation ||= begin
      bounds_x, bounds_y = prawn.bounds.anchor
      Matrix[[1, 0, bounds_x], [0, 1, bounds_y], [0, 0, 1]]
    end
  end

  def bounding_box_corners
    left, top = prawn.bounds.top_left
    right, bottom = prawn.bounds.bottom_right

    [
      [left, top],
      [left, bottom],
      [right, top],
      [right, bottom]
    ]
  end

  def compute_wrapping(wrap, from, to, matrix)
    return [1, matrix] if wrap == :pad

    # Transform the start and end points of the gradient into PDF page space.
    page_from = matrix * Vector[from[0], from[1], 1.0]
    page_to = matrix * Vector[to[0], to[1], 1.0]

    ab = page_to - page_from

    # Project each corner of the bounding box onto the line made by the
    # gradient. The formula for projecting a point C onto a line formed from
    # point A to point B is as follows:
    #
    # AB = B - A
    # AC = C - A
    # t = (AB dot AC) / (AB dot AB)
    # P = A + (AB * t)
    #
    # We don't actually need the final point P, we only need the parameter "t",
    # so that we know how many times to repeat the gradient.
    t_for_corners = bounding_box_corners.map do |x, y|
      ac = Vector[x, y, 1.0] - page_from
      ab.dot(ac) / ab.dot(ab)
    end

    t_min, t_max = t_for_corners.minmax

    repeat_count = (t_max - t_min).ceil

    delta = if shading_type == 2 # Linear
              shift_count = t_min.negative? ? t_min.floor : t_min.ceil
              ab.normalize * shift_count * ab.magnitude
            else # Radial
              []
            end

    wrap_transform = translation_matrix(delta[0], delta[1]) *
                     translation_matrix(page_from[0], page_from[1]) *
                     scale_matrix(repeat_count) *
                     translation_matrix(-page_from[0], -page_from[1])

    [repeat_count, wrap_transform * matrix]
  end
end
