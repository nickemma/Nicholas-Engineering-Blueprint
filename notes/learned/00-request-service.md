# Phase 0 self-test

Answer these from memory, without the guide or the code, then check yourself against [the lesson](../../lessons/00-request-service/TEACHING.md). Where a question says "predict", write your prediction **before** you run anything.

## A. Terminal and process

1. What does `pwd` print, and why do relative paths depend on it?
2. You run `go build -o hello .` and then `ls -l hello`. Is `hello` a program or a process? When does it become the other one?
3. What does `ss -ltnp | grep 8080` show, and what does each of `-l`, `-t`, `-n` and `-p` do? What does the `|` do?
4. A server is running in terminal 1. You press Ctrl+C. What happens to the process, and what happens to your source files?
5. Predict: you start the step 3 server twice, in two terminals. What does the second one print, and why?

## B. HTTP

6. Name the five parts of an HTTP request and response this phase uses: method, path, ..., ..., .... Which parts are in the request, and which in the response?
7. What do `127.0.0.1` and `8080` each mean in `http://127.0.0.1:8080/health`?
8. Give the status code and meaning for each case: success, bad input from the client, unknown path, wrong method on a real path.
9. Why must a 405 response include an `Allow` header?
10. What does `curl -i` show that plain `curl` doesn't? What does `-X POST` do?

## C. Reading the code

11. In `http.HandleFunc("/health", health)`, why are there no parentheses after the second `health`? When does `health` actually run?
12. What is `w`, and what is `r`? Where does text written with `fmt.Println` go, and where does text written with `fmt.Fprintln(w, ...)` go?
13. Why is the struct field `Status` capitalised? Predict the body if it were lowercase. Which command warns you about it?
14. What does `` `json:"status"` `` do?
15. Predict the full response body for `POST /health` if the `return` after `methodNotAllowed(...)` were deleted. Explain why.
16. Predict the `Content-Type` of `GET /health` if `w.Header().Set("Content-Type", ...)` were moved below the `Encode` call. Explain why.

## D. Routing

17. Which handler runs for each path, and why? `/health`, `/greet?name=Ada`, `/`, `/unknown`, `/greet/extra`.
18. What is the difference between the patterns `/greet` and `/greet/`?
19. Why does `greet` check `r.URL.Path != "/"` itself? What goes wrong without the check?
20. Does Go's router in Phase 0 choose a handler by method, by path, or both? Where is the other one checked?
21. Give two reasons the finished service builds its own `ServeMux` in `newMux()` instead of using the default router.

## E. Validation

22. Predict the status for each: `/greet?name=Ada`, `/greet`, `/greet?name=%20%20`, `/greet?name=` followed by 40 `a`s, then 41 `a`s.
23. What does `strings.TrimSpace` change about the rules, and why does it matter for a name of only spaces?
24. Why use `utf8.RuneCountInString` rather than `len`? Give an input where the two disagree.
25. The handler echoes the name back. Under what change would that become a security bug?
26. Validation "is a contract, not a guarantee of safety". Explain that sentence with an example.

## F. Tests

27. What does a handler test (calling `health(response, request)` directly) prove? What does it **not** prove?
28. What does a router test (`mux.ServeHTTP`) add?
29. What does `httptest.NewServer` add that the router test doesn't?
30. What does curl against `go run .` prove that no test in `main_test.go` proves?
31. In a table-driven test, what does `t.Run(tt.name, ...)` give you?
32. Why test 40 **and** 41 characters?
33. Write the command that runs only the `TestRoutes` subtests whose names start with `greet`. Why is the `^` needed?
34. You change `"ok"` to `"ready"`. Which tests fail, and why does each one fail?
35. Describe red, green and refactor. Why must you see the test fail first?
36. Coverage is 87%. Name the code that isn't covered and say whether that is a problem.

## G. Tooling and CI

37. What do `gofmt -l .`, `go vet ./...` and `go test -race ./...` each check?
38. What question does CI answer that running tests on your laptop doesn't?
39. In the workflow file, what do `on`, `runs-on`, `uses: actions/checkout` and `go-version-file` each do?
40. Why name files explicitly in `git add` instead of using `git add .`?

## H. Explain it whole

41. Without notes, draw the path of `curl -i 'http://127.0.0.1:8080/greet?name=Ada'` from the keyboard to the printed response, naming every component and what it does.
42. Rebuild the finished Phase 0 service from a blank folder in 30 minutes, with tests. Which parts did you need to look up?
