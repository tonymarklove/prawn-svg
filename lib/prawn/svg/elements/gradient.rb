class Prawn::SVG::Elements::Gradient < Prawn::SVG::Elements::Base
  attr_reader :parent_gradient
  attr_reader :x1, :y1, :x2, :y2, :cx, :cy, :fx, :fy, :radius, :units, :stops, :gradient_matrix

  TAG_NAME_TO_TYPE = {
    'linearGradient' => :linear,
    'radialGradient' => :radial
  }.freeze

  def parse
    # A gradient tag without an ID is inaccessible and can never be used
    raise SkipElementQuietly if attributes['id'].nil?

    @parent_gradient = document.gradients[href_attribute[1..]] if href_attribute && href_attribute[0] == '#'
    assert_compatible_prawn_version
    load_gradient_configuration
    load_coordinates
    load_stops

    document.gradients[attributes['id']] = self

    raise SkipElementQuietly # we don't want anything pushed onto the call stack
  end

  def gradient_arguments(element)
    arguments = specific_gradient_arguments(element)
    return unless arguments

    # Convert the y-coords into PDF page-space
    arguments[:from][1] = y(arguments[:from][1])
    arguments[:to][1] = y(arguments[:to][1])

    arguments.merge({ stops: stops, apply_transformations: true })
  end

  def derive_attribute(name)
    attributes[name] || parent_gradient&.derive_attribute(name)
  end

  private

  attr_reader :transform_matrix

  def apply_transform(x, y)
    return [x, y] unless transform_matrix

    (transform_matrix * Vector[x, y, 1]).to_a
  end

  def specific_gradient_arguments(element)
    if units == :bounding_box
      bounding_x1, bounding_y1, bounding_x2, bounding_y2 = element.bounding_box
      return if bounding_y2.nil?

      width = bounding_x2 - bounding_x1
      height = bounding_y1 - bounding_y2
    end

    case [type, units]
    when [:linear, :bounding_box]
      xp1, yp1 = apply_transform(x1, y1)
      xp2, yp2 = apply_transform(x2, y2)
      from = [bounding_x1 + (width * xp1), y(bounding_y1) + (height * yp1)]
      to   = [bounding_x1 + (width * xp2), y(bounding_y1) + (height * yp2)]

      { from: from, to: to }

    when [:linear, :user_space]
      { from: apply_transform(x1, y1), to: apply_transform(x2, y2) }

    when [:radial, :bounding_box]
      cxp, cyp = apply_transform(cx, cy)
      fxp, fyp = apply_transform(fx, fy)
      center = [bounding_x1 + (width * cxp), y(bounding_y1) + (height * cyp)]
      focus  = [bounding_x1 + (width * fxp), y(bounding_y1) + (height * fyp)]

      @gradient_matrix = calculate_gradient_matrix(focus[0], focus[1], width, height)

      { from: focus, r1: 0, to: center, r2: radius * [width, height].max }

    when [:radial, :user_space]
      { from: apply_transform(fx, fy), r1: 0, to: apply_transform(cx, cy), r2: radius }

    else
      raise 'unexpected type/unit system'
    end
  end

  def calculate_gradient_matrix(x, y, width, height)
    # Scaling factors in x and y
    if width > height
      sx = 1.0
      sy = height / width
    else
      sx = width / height
      sy = 1.0
    end

    # # Move the center to the origin
    # t1 = Matrix[[1.0, 0.0, -x], [0.0, 1.0, y], [0.0, 0.0, 1.0]]
    # # Scale by box size
    # s = Matrix[[sx, 0.0, 0.0], [0.0, sy, 0.0], [0.0, 0.0, 1.0]]
    # # Move the center back to where it was
    # t2 = Matrix[[1.0, 0.0, x], [0.0, 1.0, -y], [0.0, 0.0, 1.0]]
    # m1 = t2 * s * t1

    # This is equivalent to "translate(<x>, <y>) scale(sx sy) translate(-<x>, -<y>)",
    # we have simply precomputed it for efficiency.
    m2 = Matrix[[sx, 0.0, (-sx * x) + x], [0.0, sy, (sy * y) - y], [0.0, 0.0, 1.0]]

    # puts m1.inspect
    # puts m2.inspect

    m2
  end

  def type
    TAG_NAME_TO_TYPE.fetch(name)
  end

  def assert_compatible_prawn_version
    if (Prawn::VERSION.split('.').map(&:to_i) <=> [2, 2, 0]) == -1
      raise SkipElementError, "Prawn 2.2.0+ must be used if you'd like prawn-svg to render gradients"
    end
  end

  def load_gradient_configuration
    @units = derive_attribute('gradientUnits') == 'userSpaceOnUse' ? :user_space : :bounding_box

    if (transform = derive_attribute('gradientTransform'))
      @transform_matrix = parse_transform_attribute(transform, space: :svg)
    end

    if (spread_method = derive_attribute('spreadMethod')) && spread_method != 'pad'
      warnings << "prawn-svg only currently supports the 'pad' spreadMethod attribute value"
    end
  end

  def load_coordinates
    case [type, units]
    when [:linear, :bounding_box]
      @x1 = percentage_or_proportion(derive_attribute('x1'), 0)
      @y1 = percentage_or_proportion(derive_attribute('y1'), 0)
      @x2 = percentage_or_proportion(derive_attribute('x2'), 1)
      @y2 = percentage_or_proportion(derive_attribute('y2'), 0)

    when [:linear, :user_space]
      @x1 = x(derive_attribute('x1'))
      @y1 = y_pixels(derive_attribute('y1'))
      @x2 = x(derive_attribute('x2'))
      @y2 = y_pixels(derive_attribute('y2'))

    when [:radial, :bounding_box]
      @cx = percentage_or_proportion(derive_attribute('cx'), 0.5)
      @cy = percentage_or_proportion(derive_attribute('cy'), 0.5)
      @fx = percentage_or_proportion(derive_attribute('fx'), cx)
      @fy = percentage_or_proportion(derive_attribute('fy'), cy)
      @radius = percentage_or_proportion(derive_attribute('r'), 0.5)

    when [:radial, :user_space]
      @cx = x(derive_attribute('cx') || '50%')
      @cy = y_pixels(derive_attribute('cy') || '50%')
      @fx = x(derive_attribute('fx') || derive_attribute('cx'))
      @fy = y_pixels(derive_attribute('fy') || derive_attribute('cy'))
      @radius = pixels(derive_attribute('r') || '50%')

    else
      raise 'unexpected type/unit system'
    end
  end

  def load_stops
    stop_elements = source.elements.map do |child|
      element = Prawn::SVG::Elements::Base.new(document, child, [], Prawn::SVG::State.new)
      element.process
      element
    end.select do |element|
      element.name == 'stop' && element.attributes['offset']
    end

    @stops = stop_elements.each.with_object([]) do |child, result|
      offset = percentage_or_proportion(child.attributes['offset'])

      # Offsets must be strictly increasing (SVG 13.2.4)
      offset = result.last.first if result.last && result.last.first > offset

      if (color = Prawn::SVG::Color.css_color_to_prawn_color(child.properties.stop_color))
        result << [offset, color]
      end
    end

    if stops.empty?
      if parent_gradient.nil? || parent_gradient.stops.empty?
        raise SkipElementError, 'gradient does not have any valid stops'
      end

      @stops = parent_gradient.stops
    else
      stops.unshift([0, stops.first.last]) if stops.first.first.positive?
      stops.push([1, stops.last.last])     if stops.last.first < 1
    end
  end

  def percentage_or_proportion(string, default = 0)
    string = string.to_s.strip
    percentage = false

    if string[-1] == '%'
      percentage = true
      string = string[0..-2]
    end

    value = Float(string, exception: false)
    return default unless value

    if percentage
      value / 100.0
    else
      value
    end
  end
end
