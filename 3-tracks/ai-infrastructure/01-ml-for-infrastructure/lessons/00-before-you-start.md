# 00 Before you start

> ML for infrastructure · Setup

Use a Linux x86-64 host with `uv` and Bash. The lab locks CPython 3.14 and CPU-only PyTorch. First-time dependency setup can download packages from PyPI and the PyTorch CPU index. The lab needs no GPU, no cloud account, and no production job data.

From the Blueprint checkout, save its path and create a scratch directory.

~~~bash
uv --version
export blueprint="$PWD"
scratch=$(mktemp -d)
cd "$scratch"
~~~

The module uses a synthetic job-duration problem. You will build one immutable dataset, compare two baselines and a small model on late-held-out jobs, then promote and roll back a serving version. The next AI track module studies larger model serving and distribution.

### Select Python

Use the current CPython 3.14 line.

Create `.python-version`.

<!-- file: .python-version -->
~~~text
3.14
~~~

### Pin the CPU dependencies

Use PyArrow for columns, PyTorch for training, and SafeTensors for weights.

Create `pyproject.toml`.

<!-- file: pyproject.toml -->
~~~toml
[project]
name = "switchyard-ml-lab"
version = "0.1.0"
requires-python = ">=3.14,<3.15"
dependencies = [
    "numpy==2.5.5",
    "pyarrow==26.0.0",
    "safetensors==0.8.0",
    "torch==2.15.0",
]

[tool.uv]
package = false
environments = ["sys_platform == 'linux' and platform_machine == 'x86_64'"]

[tool.uv.sources]
torch = { index = "pytorch-cpu" }

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true
~~~

### Keep the resolved versions and hashes

Use the same artifact dependencies when you build and when you replay.

Create `uv.lock`.

<!-- file: uv.lock -->
~~~toml
version = 1
revision = 3
requires-python = "==3.14.*"
resolution-markers = [
    "platform_machine == 'x86_64' and sys_platform == 'linux'",
]
supported-markers = [
    "platform_machine == 'x86_64' and sys_platform == 'linux'",
]

[[package]]
name = "filelock"
version = "4.3.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/6c/bf/a895b0b8e83d0a64d134f658e393e83998abfc22bbb8b58181ce55268706/filelock-4.3.0.tar.gz", hash = "sha256:143407310acf479e82d88068e3b9a6486f45fb410c0ed8729fe7359eaabeb6f1", size = 742199, upload-time = "2026-11-22T02:15:03.187Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/68/66/870b527908a06c7ec0e91239bd2c4d0bb22921efd4f915428b4e47d461a6/filelock-4.3.0-py3-none-any.whl", hash = "sha256:f933f39f7e01249a4a49b9abab30edc6d4b874624c3de5dd0b0d137aa8adb979", size = 244553, upload-time = "2026-11-22T02:15:01.667Z" },
]

[[package]]
name = "fsspec"
version = "2026.9.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/77/cd/9be253869fc42e764de7f3dedd6969af7d44ff9c3375214a3442a6f3fc08/fsspec-2026.9.0.tar.gz", hash = "sha256:0f08147951c8cb31d844c3547d631053b127863b60be04cf06e121333ee0e2fe", size = 333545, upload-time = "2026-09-18T17:50:42.825Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/6c/c0/a98505f18594f1bce828bb159cec0fcf9860562f1a2c85913409fc8f3d9e/fsspec-2026.9.0-py3-none-any.whl", hash = "sha256:8dd6e646e99ea382bd85f97a45e6b526a442d79423a7dc673f1e2756d05fcb5f", size = 221738, upload-time = "2026-09-18T17:50:41.341Z" },
]

[[package]]
name = "jinja2"
version = "3.1.6"
source = { registry = "https://pypi.org/simple" }
dependencies = [
    { name = "markupsafe" },
]
sdist = { url = "https://files.pythonhosted.org/packages/df/bf/f7da0350254c0ed7c72f3e33cef02e048281fec7ecec5f032d4aac52226b/jinja2-3.1.6.tar.gz", hash = "sha256:0137fb05990d35f1275a587e9aee6d56da821fc83491a0fb838183be43f66d6d", size = 245115, upload-time = "2025-03-05T20:05:02.478Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/62/a1/3d680cbfd5f4b8f15abc1d571870c5fc3e594bb582bc3b64ea099db13e56/jinja2-3.1.6-py3-none-any.whl", hash = "sha256:85ece4451f492d0c13c5dd7c13a64681a86afae63a5f347908daf103ce6d2f67", size = 134899, upload-time = "2025-03-05T20:05:00.369Z" },
]

[[package]]
name = "markupsafe"
version = "3.0.4"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/38/9b/e422a865e1d5d57d0e509b4e0bf1c1a70a7f6382c29a5aa428df994c8bc8/markupsafe-3.0.4.tar.gz", hash = "sha256:2e9ad7dd851bf45fab9f75cbff4cb493fee9979e8d8c7c9c3ee119022518edd6", size = 153777, upload-time = "2026-10-02T23:07:22.29Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/60/d0/34b810107d83840e768bf485de795893ebbae35b26ab061b487adfa0a692/markupsafe-3.0.4-cp314-cp314-ios_13_0_x86_64_iphonesimulator.whl", hash = "sha256:8909c2f1c6dd65e054ac4b573a91c8384d1492281e55d82d159d653f7a13adf6", size = 11447, upload-time = "2026-10-02T23:05:35.302Z" },
    { url = "https://files.pythonhosted.org/packages/8f/db/d7282caf7ab03af44d5d6fdbaa019b35c7d7f1c90588b839c07cba640d6a/markupsafe-3.0.4-cp314-cp314-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl", hash = "sha256:a8e9f292fcda89b324f2f5c91d13f1424a153e40fc2756f38ee23b15835ff300", size = 23049, upload-time = "2026-10-02T23:05:41.864Z" },
    { url = "https://files.pythonhosted.org/packages/b4/b0/b505e8a361ba557dbf3b3aa7331ea39b00d2022a26e925ff8463b9714bb3/markupsafe-3.0.4-cp314-cp314-musllinux_1_2_x86_64.whl", hash = "sha256:0d9c47709875fdb321452056622e930c52afbc07a7d780762fbb8b4d91ce6fa4", size = 23081, upload-time = "2026-10-02T23:05:48.611Z" },
    { url = "https://files.pythonhosted.org/packages/30/77/680998b54efdea06fc114565cd739b6d059f826a0279219b218dfa750d29/markupsafe-3.0.4-cp314-cp314t-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl", hash = "sha256:b4a635a0487774f841cb1fb62e907e7195cc95bc761e053184b8acc3ceb20733", size = 23623, upload-time = "2026-10-02T23:05:58.557Z" },
    { url = "https://files.pythonhosted.org/packages/c6/61/ebda1307864b409e6b3115757a3d4a09cca46cfb6cc65191b5de226b424b/markupsafe-3.0.4-cp314-cp314t-musllinux_1_2_x86_64.whl", hash = "sha256:a9f54054101545a9a9cccefddf54316aa6e4491611fcbef9e91b3b6bebec04f6", size = 23668, upload-time = "2026-10-02T23:06:05.9Z" },
]

[[package]]
name = "mpmath"
version = "1.3.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/e0/47/dd32fa426cc72114383ac549964eecb20ecfd886d1e5ccf5340b55b02f57/mpmath-1.3.0.tar.gz", hash = "sha256:7a28eb2a9774d00c7bc92411c19a89209d5da7c4c9a9e227be8330a23a25b91f", size = 508106, upload-time = "2023-03-07T16:47:11.061Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/43/e3/7d92a15f894aa0c9c4b49b8ee9ac9850d6e63b03c9c32c0367a13ae62209/mpmath-1.3.0-py3-none-any.whl", hash = "sha256:a0b2b9fe80bbcd81a6647ff13108738cfb482d481d826cc0e02f5b35e5c88d2c", size = 536198, upload-time = "2023-03-07T16:47:09.197Z" },
]

[[package]]
name = "networkx"
version = "3.7"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/dc/76/3af777226b63a5e64a6b36b1ec5855c14e2b94a37096d4760e595fc43511/networkx-3.7.tar.gz", hash = "sha256:fd77a511bd90f39f3d016351345b52cf5319b813bdca01de3f755d3cca62e96a", size = 1866482, upload-time = "2026-09-21T16:45:16.974Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/7e/cd/fe58041e9011f307c490e3e17dd48cc516448f7c698a3f2d9d9d65d7e6a8/networkx-3.7-py3-none-any.whl", hash = "sha256:e3fd2c13a7814cee3746340d8d7f8598a67f16a58bf47fb7f8793fab6efca1b0", size = 2142205, upload-time = "2026-09-21T16:45:14.609Z" },
]

[[package]]
name = "numpy"
version = "2.5.5"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/4e/3a/8770c288c47f0b5c2a786d3c20e79f66fd245f2d42cd232d7cd5e00e83e5/numpy-2.5.5.tar.gz", hash = "sha256:5cddc243c75114ba845f01b1f87aca1572dbf7b6c2d88636ed3e1d2bccd7f1bf", size = 20873892, upload-time = "2026-11-15T21:32:28.607Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/a4/1f/fcdce1061fba2bfb2e9bfda01fbd8132d5f7522a4f7c8e2b2f629d54ee38/numpy-2.5.5-cp314-cp314-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", hash = "sha256:c48960d420e90cf305cb1fde0d4e6082cc90512cda87a9acf0b6e04e91cf4abe", size = 15718051, upload-time = "2026-11-15T21:31:08.12Z" },
    { url = "https://files.pythonhosted.org/packages/66/14/60c3fc30e63876e44212392eacd4ea1bd201c29835c99f42daa04c2501e4/numpy-2.5.5-cp314-cp314-musllinux_1_2_x86_64.whl", hash = "sha256:e10e81d1db6c8fa507f61bebfd1ea383971dbc40c2005ed4db88fac5538b1ef6", size = 17079719, upload-time = "2026-11-15T21:31:13.245Z" },
    { url = "https://files.pythonhosted.org/packages/93/43/85cfae380e4e2fe1d246c39a12c88c7a224e751604b6fa13236df3b86600/numpy-2.5.5-cp314-cp314t-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl", hash = "sha256:479e43c183049ec1a820eeb36549e493924f56b3e893a1d5865d0fff12abad47", size = 15751077, upload-time = "2026-11-15T21:31:29.851Z" },
    { url = "https://files.pythonhosted.org/packages/a0/b1/75f51d9e2fb970228bd7599d46f34eb0829070b4df8b293c43fdf1c81c44/numpy-2.5.5-cp314-cp314t-musllinux_1_2_x86_64.whl", hash = "sha256:2a9c502cdb9a3050ac1686774624cc278658b11f72e11b971a3a8542d6ded357", size = 17122494, upload-time = "2026-11-15T21:31:34.267Z" },
]

[[package]]
name = "pyarrow"
version = "26.0.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/ec/34/17c34cb38e5d940e38f0f0d9fdfa0e8a506676409ea9b85aff7e3079f831/pyarrow-26.0.0.tar.gz", hash = "sha256:0cccd36e00ea3afeb52ded61f2721ce71f604853d70c45365c58324eb773d6ae", size = 1239433, upload-time = "2026-10-09T08:26:25.315Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/ec/c1/0c1ff38ab7df1b2cf54cf0ad9f19a516c4e416c6c9b4c966cc2c9d587f77/pyarrow-26.0.0-cp314-cp314-manylinux_2_28_x86_64.whl", hash = "sha256:ab6914db225d7f399652ae1f08588dfbc9efe617612715701e3d9d5cfa5ca19f", size = 53951865, upload-time = "2026-10-09T08:23:57.692Z" },
    { url = "https://files.pythonhosted.org/packages/a8/32/033ef9dba80976820190e292a10a5a23e9406572b76bbeb4d685d90e5c8d/pyarrow-26.0.0-cp314-cp314-musllinux_1_2_x86_64.whl", hash = "sha256:6e949744dcfc2d379808f7013c5f9cafaf0f817656dff7d46c6931528dd1784b", size = 57411588, upload-time = "2026-10-09T08:24:12.043Z" },
    { url = "https://files.pythonhosted.org/packages/4b/cb/b6d5048cf3178be9678f5c9c60040199894b2f69c3439c87ced91fd24da9/pyarrow-26.0.0-cp314-cp314t-manylinux_2_28_x86_64.whl", hash = "sha256:210cc9b83888b87cdc8f793eebb264f22b20d0dedbedefc73b9687a7047b4747", size = 53906419, upload-time = "2026-10-09T08:24:33.536Z" },
    { url = "https://files.pythonhosted.org/packages/e2/23/fce251cd6b0546dfc181b00d5c8ef1c95a8c4cae83266bc3dfd5f719c62c/pyarrow-26.0.0-cp314-cp314t-musllinux_1_2_x86_64.whl", hash = "sha256:290a74c48e9491b436fd5edacfadf357943f82aa45c81110bd83a69aab33d1cf", size = 57388010, upload-time = "2026-10-09T08:24:48.186Z" },
]

[[package]]
name = "safetensors"
version = "0.8.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/45/06/f955dbbb1859e3bd23c8ac6141af5106e7ad5fedec4a3a6e3d60f94b7001/safetensors-0.8.0.tar.gz", hash = "sha256:fabaf3e0f18a6618d9b36560682562157f77c2b71fcffc7b432be2baed9d753d", size = 325846, upload-time = "2026-06-09T07:52:25.563Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/28/50/f203ff3a3ddfe19308efc83c5a3a29ed02bf786732ec35e68bf9162f3365/safetensors-0.8.0-cp310-abi3-manylinux_2_17_x86_64.manylinux2014_x86_64.whl", hash = "sha256:fd6f3f93c9a0a7cc2788ee63fb763353d4bd2e89b0751bc78fcf7dda00bea774", size = 516040, upload-time = "2026-06-09T07:52:16.29Z" },
    { url = "https://files.pythonhosted.org/packages/27/43/41c1621732edd934d868a00d1b891584c892a7b62a9aab82ea5a0a5623ee/safetensors-0.8.0-cp310-abi3-musllinux_1_2_x86_64.whl", hash = "sha256:8e080062fcde23be189565e1c3305d16751a218ecf9412c8601e64204eb6f846", size = 722361, upload-time = "2026-06-09T07:52:23.924Z" },
]

[[package]]
name = "setuptools"
version = "84.2.1"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/70/b3/c19426f783614d625699a4b247faf628ea9ab1db228674491767b417f9e1/setuptools-84.2.1.tar.gz", hash = "sha256:3ff8b3b5492a0aa66960f4419365a86b84e013070d4313e4d4a6894f5d64d6bc", size = 1230289, upload-time = "2026-10-20T19:01:37.742Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/ef/55/6dc6d6bb953bdfc52519a0059592c52b6e3b8ad51cf8256dffceb55b0610/setuptools-84.2.1-py3-none-any.whl", hash = "sha256:ca140b45d5325a9478f880e351484f62fef15f336462e449ca0c03c873d589c2", size = 876263, upload-time = "2026-10-20T19:01:35.678Z" },
]

[[package]]
name = "switchyard-ml-lab"
version = "0.1.0"
source = { virtual = "." }
dependencies = [
    { name = "numpy" },
    { name = "pyarrow" },
    { name = "safetensors" },
    { name = "torch" },
]

[package.metadata]
requires-dist = [
    { name = "numpy", specifier = "==2.5.5" },
    { name = "pyarrow", specifier = "==26.0.0" },
    { name = "safetensors", specifier = "==0.8.0" },
    { name = "torch", specifier = "==2.15.0", index = "https://download.pytorch.org/whl/cpu" },
]

[[package]]
name = "sympy"
version = "1.14.0"
source = { registry = "https://pypi.org/simple" }
dependencies = [
    { name = "mpmath" },
]
sdist = { url = "https://files.pythonhosted.org/packages/83/d3/803453b36afefb7c2bb238361cd4ae6125a569b4db67cd9e79846ba2d68c/sympy-1.14.0.tar.gz", hash = "sha256:d3d3fe8df1e5a0b42f0e7bdf50541697dbe7d23746e894990c030e2b05e72517", size = 7793921, upload-time = "2025-04-27T18:05:01.611Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/a2/09/77d55d46fd61b4a135c444fc97158ef34a095e5681d0a6c10b75bf356191/sympy-1.14.0-py3-none-any.whl", hash = "sha256:e091cc3e99d2141a0ba2847328f5479b05d94a6635cb96148ccb3f34671bd8f5", size = 6299353, upload-time = "2025-04-27T18:04:59.103Z" },
]

[[package]]
name = "torch"
version = "2.15.0+cpu"
source = { registry = "https://download.pytorch.org/whl/cpu" }
dependencies = [
    { name = "filelock" },
    { name = "fsspec" },
    { name = "jinja2" },
    { name = "networkx" },
    { name = "setuptools" },
    { name = "sympy" },
    { name = "typing-extensions" },
]
wheels = [
    { url = "https://download-r2.pytorch.org/whl/cpu/torch-2.15.0%2Bcpu-cp314-cp314-manylinux_2_28_x86_64.whl", hash = "sha256:f089c94912c955269a20e5fee6b6a371209b610849c9ece26e908a748d87a723", upload-time = "2026-10-28T13:19:32Z" },
    { url = "https://download-r2.pytorch.org/whl/cpu/torch-2.15.0%2Bcpu-cp314-cp314t-manylinux_2_28_x86_64.whl", hash = "sha256:17d66ae6f8a49d4dfca368b50b7dc15f7129175e80b4ae2832dfa0cce86d3159", upload-time = "2026-10-28T13:19:55Z" },
]

[[package]]
name = "typing-extensions"
version = "4.16.0"
source = { registry = "https://pypi.org/simple" }
sdist = { url = "https://files.pythonhosted.org/packages/f6/cc/6253133b5bb138fc3306cebfbda2c520f545d36b5be2c7255cc528bb45d6/typing_extensions-4.16.0.tar.gz", hash = "sha256:dc983d19a509c94dba722ee6abd33940f7c05a89e243c47e907eb4db6f1a43e5", size = 113555, upload-time = "2026-07-02T08:40:05.92Z" }
wheels = [
    { url = "https://files.pythonhosted.org/packages/49/d3/b8441a820a491ddfc024b0b0cf0393375b75ea13866d9c66727e54c2fc80/typing_extensions-4.16.0-py3-none-any.whl", hash = "sha256:481caa481374e813c1b176ada14e97f1f67a4539ce9cfeb3f350d78d6370c2e8", size = 45571, upload-time = "2026-07-02T08:40:04.659Z" },
]
~~~

## Check it

~~~bash
uv sync --locked
uv run --locked python -c "import pyarrow, torch; print(torch.__version__, pyarrow.__version__)"
~~~

<!-- run: uv sync --locked && uv run --locked python -c "import pyarrow, torch; print(torch.__version__, pyarrow.__version__)" -->

The reference printed `2.15.0+cpu 26.0.0`. If the lock cannot resolve on your OS, run the lab on a supported Linux x86-64 environment.
