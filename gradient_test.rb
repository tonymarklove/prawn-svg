require 'debug'
require 'prawn'
require 'vips'
require_relative 'lib/prawn-svg'

page_width = 1200
page_height = 800

input_file = 'gradient_test.svg'

prawn_document = Prawn::Document.new(margin: 0, page_size: [page_width, page_height])

prawn_document.bounding_box([10, 790], width: page_width / 2, height: page_height / 2) do
#   prawn_document.rotate(-10, origin: [page_width/2, page_height/2]) do
    prawn_document.svg(File.read(input_file), width: page_width, height: page_height)
#   end
end

File.write('gradient_test_out.pdf', prawn_document.render)

vips_image = Vips::Image.thumbnail(input_file, page_width)
vips_image.pngsave('gradient_test_out_direct.png')

vips_image = Vips::Image.thumbnail('gradient_test_out.pdf', page_width)
vips_image.pngsave('gradient_test_out_via_pdf.png')
