import io

import pytest
from PIL import Image

from app.images import prepare_image


def test_image_reencoding_removes_metadata():
    image = Image.new("RGB", (1200, 1400))
    exif = Image.Exif()
    exif[270] = "private metadata"
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", exif=exif)
    with Image.open(io.BytesIO(prepare_image(buffer.getvalue()))) as cleaned:
        assert cleaned.size == (1200, 1400)
        assert not cleaned.getexif()


@pytest.mark.parametrize("size", [(480, 640), (1080, 4000)])
def test_small_after_resizing_is_rejected(size):
    buffer = io.BytesIO()
    Image.new("RGB", size).save(buffer, format="PNG")
    with pytest.raises(ValueError, match="1080"):
        prepare_image(buffer.getvalue())
