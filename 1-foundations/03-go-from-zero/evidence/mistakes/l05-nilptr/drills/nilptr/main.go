package main

import "fmt"

type Task struct {
	ID    int
	Title string
}

func main() {
	var p *Task // a pointer to nothing yet
	fmt.Println(p == nil)
	fmt.Println(p.Title)
}
