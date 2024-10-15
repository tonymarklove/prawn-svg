class Prawn::SVG::GradientRenderer
  include Prawn::SVG::TransformUtils

  def initialize(prawn, draw_type, from:, to:, stops:, matrix: nil, r1: nil, r2: nil, wrap: :pad)
    @prawn = prawn
    @draw_type = draw_type

    if r1
      @shading_type = 3
      @coordinates = [*from, r1, *to, r2]
    else
      @shading_type = 2
      @coordinates = [*from, *to]
    end

    @stop_offsets, @color_stops, @opacity_stops = process_stop_arguments(stops)

    @gradient_matrix = load_matrix(matrix) || Matrix.identity(3)
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

  attr_reader :prawn, :draw_type, :shading_type, :coordinates,
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
      offset, color, opacity = if stop.is_a?(Hash)
                                 [stop[:offset], stop[:color], stop[:opacity] || 1.0]
                               else
                                 [stop[0], stop[1], stop[2] || 1.0]
                               end

      transparency = true if opacity < 1

      stop_offsets << offset
      color_stops << prawn.send(:normalize_color, color)
      opacity_stops << [opacity]
    end

    opacity_stops = nil unless transparency

    [stop_offsets, color_stops, opacity_stops]
  end

  def create_transparency_graphics_state
    prawn.renderer.min_version(1.4)

    bounds_x, bounds_y = prawn.bounds.anchor
    transform = Matrix[[1, 0, bounds_x], [0, 1, bounds_y], [0, 0, 1]] * gradient_matrix

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
              Function:    create_shading_function(stop_offsets, opacity_stops),
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
    transform = gradient_transform.round(2)

    # FIXME: for radial as well
    a = transform * Vector[coordinates[0], coordinates[1], 1.0]
    b = transform * Vector[coordinates[2], coordinates[3], 1.0]

    ab = (b - a)

    repeat_count = 1

    ta = Matrix[[1.0, 0.0, -a[0]], [0.0, 1.0, -a[1]], [0.0, 0.0, 1.0]]
    scale = Matrix[[repeat_count, 0.0, 0.0], [0.0, repeat_count, 0.0], [0.0, 0.0, 1.0]]
    tb = Matrix[[1.0, 0.0, a[0] - ab[0]], [0.0, 1.0, a[1] - ab[1]], [0.0, 0.0, 1.0]]

    # transform = tb * scale * ta * transform

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
        # Background:  [1, 0, 1]
      }
    )
  end

  def create_shading_function(offsets, stop_values, wrap = :pad, repeat_count = 1)
    gradient_func = create_shading_function_for_stops(offsets, stop_values)

    # Return the gradient function if there is no need to repeat.
    return gradient_func if wrap == :pad

    encode = repeat_count.times.with_object([]) do |num, memo|
      if wrap == :reflect && num.even?
        memo.push(1, 0)
      else
        memo.push(0, 1)
      end
    end

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

  def gradient_transform
    current_transform = load_matrix(
      prawn.current_transformation_matrix_with_translation(*prawn.bounds.anchor)
    )

    current_transform * gradient_matrix
  end
end
