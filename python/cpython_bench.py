import ast, sys, time
path, iterations = sys.argv[1], int(sys.argv[2])
source = open(path, "rb").read()
size = len(source)
def run(label, function):
    for _ in range(max(iterations // 10, 1)):
        function()
    best = None
    for _ in range(5):
        start = time.perf_counter()
        for _ in range(iterations):
            function()
        elapsed = time.perf_counter() - start
        best = elapsed if best is None or elapsed < best else best
    print(f"{sys.version.split()[0]:8} {label:10} {size * iterations / best / 2**20:8.2f} MB/s")
run("ast.parse", lambda: compile(source, "x", "exec", ast.PyCF_ONLY_AST))
run("compile", lambda: compile(source, "x", "exec"))
