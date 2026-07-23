class Prawn::SVG::Elements::Anchor < Prawn::SVG::Elements::Base
  def parse
    href = href_attribute
    state.anchor_href = href unless href.nil? || href.strip.empty?
  end

  def container?
    true
  end
end
