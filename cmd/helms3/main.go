package main

import (
	"fmt"
	"log"
	"os"
	"time"

	"gopkg.in/alecthomas/kingpin.v2"
)

var (
	version = "master"
)

const (
	actionPush = "push"
	actionInit = "init"

	defaultTimeout = time.Second * 5
)

func main() {
	if len(os.Args) == 5 {
		if err := runProxy(os.Args[4]); err != nil {
			log.Fatal(err)
		}
		return
	}

	cli := kingpin.New("helm s3", "")
	cli.Version(version)
	initCmd := cli.Command(actionInit, "Initialize empty repository on AWS S3.")
	initURI := initCmd.Arg("uri", "URI of repository, e.g. s3://awesome-bucket/charts").
		Required().
		String()
	pushCmd := cli.Command(actionPush, "Push chart to repository.")
	pushChartPath := pushCmd.Arg("chartPath", "Path to a chart, e.g. ./epicservice-0.5.1.tgz").
		Required().
		String()
	pushTargetRepository := pushCmd.Arg("repo", "Target repository to runPush").
		Required().
		String()
	action := kingpin.MustParse(cli.Parse(os.Args[1:]))
	if action == "" {
		cli.Usage(os.Args[1:])
		os.Exit(0)
	}

	switch action {

	case actionInit:
		if err := runInit(*initURI); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("Initialized empty repository at %s\n", *initURI)
		return

	case actionPush:
		if err := runPush(*pushChartPath, *pushTargetRepository); err != nil {
			log.Fatal(err)
		}
		return

	}
}
